Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$WshShell = New-Object -ComObject WScript.Shell

# --- CONFIG ---
$CONTROLLER_MODEL = "gemini-3-flash-preview:cloud"
$VISION_MODEL     = "ministral-3:14b-cloud"
$OLLAMA_BASE      = "http://192.168.50.135:11434"

# --- SAFETY MANIFEST ---
$SafetyTable = @(
    @{ Pattern = "rm ";             Description = "Recursive Removal" }
    @{ Pattern = "del ";            Description = "File Deletion" }
    @{ Pattern = "format ";         Description = "Disk Formatting" }
    @{ Pattern = "Remove-Item";     Description = "PS Item Deletion" }
    @{ Pattern = "Stop-Process";    Description = "Kill Tasks" }
    @{ Pattern = "shutdown ";       Description = "System Halt" }
    @{ Pattern = "Restart-Computer";Description = "System Reboot" }
)

Write-Host "`n[SAFETY MANIFEST LOADED]" -ForegroundColor Yellow
$SafetyTable | Out-String | Write-Host -ForegroundColor Gray

# --- TOOLS (OpenAI-compatible schema - Ollama supports this since late 2024) ---
$tools = @(
    @{
        type = "function"
        function = @{
            name = "see_screen"
            description = "Capture the current screen and return a detailed description using the vision model."
            parameters = @{ type = "object"; properties = @{}; required = @() }
        }
    },
    @{
        type = "function"
        function = @{
            name = "execute_command"
            description = "Execute a PowerShell command safely on the host system."
            parameters = @{
                type = "object"
                properties = @{
                    command = @{ type = "string"; description = "The exact PowerShell command to run." }
                }
                required = @("command")
            }
        }
    },
    @{
        type = "function"
        function = @{
            name = "focus_window"
            description = "Bring a window with the given title to the foreground."
            parameters = @{
                type = "object"
                properties = @{
                    title = @{ type = "string"; description = "Partial or exact window title." }
                }
                required = @("title")
            }
        }
    },
    @{
        type = "function"
        function = @{
            name = "take_action"
            description = "Send keystrokes to the currently active window."
            parameters = @{
                type = "object"
                properties = @{
                    keys = @{ type = "string"; description = "Keys in SendKeys format, e.g. 'Hello{ENTER}', '^a', '{F5}'." }
                }
                required = @("keys")
            }
        }
    },
    @{
        type = "function"
        function = @{
            name = "wait_timer"
            description = "Wait for the specified number of seconds."
            parameters = @{
                type = "object"
                properties = @{
                    seconds = @{ type = "integer"; description = "Seconds to wait." }
                }
                required = @("seconds")
            }
        }
    }
)

# --- TOOL IMPLEMENTATIONS ---
function Get-ScreenDescription {
    Write-Host "[Eyes] Capturing screen..." -ForegroundColor Yellow
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $base64 = [Convert]::ToBase64String($ms.ToArray())
    $g.Dispose(); $bmp.Dispose(); $ms.Close()

    $body = @{
        model  = $VISION_MODEL
        prompt = "Describe everything you see in detail. List all open windows and their exact titles."
        images = @($base64)
        stream = $false
    } | ConvertTo-Json -Depth 10

    $result = Invoke-RestMethod -Uri "$OLLAMA_BASE/api/generate" -Method Post -Body $body -ContentType "application/json"
    return $result.response.Trim()
}

function Execute-SafeCommand($command) {
    foreach ($rule in $SafetyTable) {
        if ($command -match [regex]::Escape($rule.Pattern)) {
            Write-Host "`n[!] SAFETY BLOCK: $($rule.Description)" -ForegroundColor Red
            if ((Read-Host "Override? (y/N)") -ne "y") { return "Command blocked by safety manifest." }
        }
    }
    Write-Host "[Shell] $command" -ForegroundColor Cyan
    try {
        $output = Invoke-Expression $command 2>&1 | Out-String
        if ([string]::IsNullOrWhiteSpace($output)) {
            return "Success."
        } else {
            return $output.Trim()
        }
    } catch {
        return "Error: $($_.Exception.Message)"
    }
}

# --- REPL ---
$global:History = @(
    @{ role = "system"; content = "You are Sammy - an autonomous agent running on a Windows PC. Always use tools when needed. Never guess what is on screen - use see_screen first if unsure." }
)

function Start-AgentREPL {
    Write-Host "`n=== Sammy Agent REPL ===`nType 'exit' to quit, 'clear' to reset context.`n" -ForegroundColor Magenta

    while ($true) {
        $input = Read-Host "You"
        if ($input -in "exit","quit") { break }
        if ($input -eq "clear") { $global:History = $global:History[0]; continue }

        $global:History += @{ role = "user"; content = $input }

        $thinking = $true
        while ($thinking) {
            $payload = @{
                model    = $CONTROLLER_MODEL
                messages = $global:History
                tools    = $tools
                tool_choice = "auto"
            } | ConvertTo-Json -Depth 20

            try {
                $response = Invoke-RestMethod -Uri "$OLLAMA_BASE/v1/chat/completions" -Method Post -Body $payload -ContentType "application/json" -TimeoutSec 300
            } catch {
                Write-Error "API Error: $($_.Exception.Response.StatusDescription)"
                $_ | Format-List -Force
                break
            }

            $choice = $response.choices[0]
            $message = $choice.message
            $global:History += $message

            if ($message.content) {
                Write-Host "`n[Sammy] $($message.content)`n" -ForegroundColor Green
            }

            if ($message.tool_calls) {
                foreach ($call in $message.tool_calls) {
                    $func = $call.function
                    $args = $func.arguments | ConvertFrom-Json -ErrorAction Stop

                    $result = switch ($func.name) {
                        "see_screen"     { Get-ScreenDescription }
                        "execute_command"{ Execute-SafeCommand $args.command }
                        "focus_window"   { 
                            $success = $WshShell.AppActivate($args.title)
                            if ($success) { "Focused window: $($args.title)" } else { "Window not found: $($args.title)" }
                        }
                        "take_action"    { [System.Windows.Forms.SendKeys]::SendWait($args.keys); "Sent keys: $($args.keys)" }
                        "wait_timer"     { Start-Sleep -Seconds $args.seconds; "Waited $($args.seconds)s" }
                    }

                    $global:History += @{
                        role = "tool"
                        tool_call_id = $call.id
                        name = $func.name
                        content = $result
                    }

                    Write-Host "[Tool -> $($func.name)] $result`n" -ForegroundColor Yellow
                }
            } else {
                $thinking = $false
            }
        }
    }
}

Start-AgentREPL
