Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$WshShell = New-Object -ComObject WScript.Shell

# --- CONFIG ---
$CONTROLLER_MODEL = "gemini-3-flash-preview:cloud"
$VISION_MODEL     = "ministral-3:14b-cloud"
$OLLAMA_BASE      = "http://192.168.50.135:11434"

# --- SAFETY SETTINGS ---
$DANGEROUS_PATTERNS = @("rm ", "del ", "format ", "shutdown ", "Remove-Item", "Stop-Process", "Restart-Computer", "Set-Content", "Out-File")

# --- GLOBAL MEMORY ---
$global:ChatHistory = @(
    @{ role = "system"; content = "You are an autonomous Windows Agent. You have vision, shell, and UI control. 1. Always use 'see_screen' to identify window titles before focusing. 2. Use 'execute_command' for system tasks. 3. Use 'take_action' for typing into focused windows." }
)

# --- TOOLS IMPLEMENTATION ---

function Get-ScreenDescription {
    Write-Host "[Eyes] Analyzing screen..." -ForegroundColor Yellow
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap($screen.Width, $screen.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bmp)
    $graphics.CopyFromScreen($screen.Location, [System.Drawing.Point]::Empty, $screen.Size)
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $base64Image = [Convert]::ToBase64String($ms.ToArray())
    $graphics.Dispose(); $bmp.Dispose(); $ms.Dispose()

    $body = @{ model = $VISION_MODEL; prompt = "Describe the open windows and their exact titles. What is Sammy looking at?"; stream = $false; images = @($base64Image) } | ConvertTo-Json
    return (Invoke-RestMethod -Uri "$OLLAMA_BASE/api/generate" -Method Post -Body $body -ContentType "application/json").response
}

function Execute-SafeCommand($command) {
    $isDangerous = $false
    foreach ($p in $DANGEROUS_PATTERNS) { if ($command -like "*$p*") { $isDangerous = $true; break } }

    if ($isDangerous) {
        Write-Host "`n⚠️  SAFETY TRIGGERED: Agent wants to run: $command" -ForegroundColor Red
        $choice = Read-Host "Allow? (y/n)"
        if ($choice -ne "y") { return "User blocked this command for safety." }
    }

    Write-Host "[Shell] Executing: $command" -ForegroundColor Cyan
    try { return (Invoke-Expression $command | Out-String) } 
    catch { return "Error: $($_.Exception.Message)" }
}

# --- TOOL DEFINITIONS FOR THE LLM ---
$tools = @(
    @{ type = "function"; function = @{ name = "see_screen"; description = "Takes a screenshot and describes windows." } },
    @{ 
        type = "function"; function = @{ 
            name = "execute_command"; description = "Run PowerShell. Use for files, folders, and system info.";
            parameters = @{ type = "object"; properties = @{ command = @{ type = "string" } }; required = @("command") }
        } 
    },
    @{ 
        type = "function"; function = @{ 
            name = "focus_window"; description = "Focus an app by title.";
            parameters = @{ type = "object"; properties = @{ title = @{ type = "string" } }; required = @("title") }
        } 
    },
    @{ 
        type = "function"; function = @{ 
            name = "take_action"; description = "Send keystrokes (e.g., 'Hello{ENTER}', '^s').";
            parameters = @{ type = "object"; properties = @{ keys = @{ type = "string" } }; required = @("keys") }
        } 
    }
)

# --- REPL ENGINE ---
function Start-AgentREPL {
    Write-Host "`n--- Sammy's AI Agent REPL ---" -ForegroundColor Blue
    Write-Host "Commands: 'exit' to quit, 'clear' to reset memory." -ForegroundColor Gray

    while ($true) {
        $userInput = Read-Host "`nREPL >"
        if ($userInput -eq "exit") { break }
        if ($userInput -eq "clear") { $global:ChatHistory = $global:ChatHistory[0]; Write-Host "Memory Cleared."; continue }
        
        $global:ChatHistory += @{ role = "user"; content = $userInput }

        $thinking = $true
        while ($thinking) {
            $body = @{ model = $CONTROLLER_MODEL; messages = $global:ChatHistory; tools = $tools } | ConvertTo-Json -Depth 10
            $resp = Invoke-RestMethod -Uri "$OLLAMA_BASE/v1/chat/completions" -Method Post -Body $body -ContentType "application/json"
            $msg = $resp.choices[0].message
            
            if (-not $msg.tool_calls) {
                Write-Host "`n[Agent]: $($msg.content)" -ForegroundColor Green
                $global:ChatHistory += $msg
                $thinking = $false
            } else {
                foreach ($tool in $msg.tool_calls) {
                    $args = $tool.function.arguments | ConvertFrom-Json
                    $output = switch ($tool.function.name) {
                        "see_screen"      { Get-ScreenDescription }
                        "execute_command" { Execute-SafeCommand -command $args.command }
                        "focus_window"    { $WshShell.AppActivate($args.title); "Focused $args.title" }
                        "take_action"     { [System.Windows.Forms.SendKeys]::SendWait($args.keys); "Keys sent." }
                    }
                    $global:ChatHistory += $msg
                    $global:ChatHistory += @{ role = "tool"; tool_call_id = $tool.id; name = $tool.function.name; content = $output }
                }
            }
        }
    }
}

Start-AgentREPL
