Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$WshShell = New-Object -ComObject WScript.Shell

# --- CONFIG ---
$CONTROLLER_MODEL = "gemini-3-flash-preview:cloud"
$VISION_MODEL     = "ministral-3:14b-cloud"
$OLLAMA_BASE      = "http://192.168.50.135:11434"

# --- SAFETY MANIFEST ---
$SafetyTable = @(
    @{ Pattern = "rm "; Description = "Recursive Removal" }
    @{ Pattern = "del "; Description = "File Deletion" }
    @{ Pattern = "format "; Description = "Disk Formatting" }
    @{ Pattern = "Remove-Item"; Description = "PS Item Deletion" }
    @{ Pattern = "Stop-Process"; Description = "Kill Tasks" }
    @{ Pattern = "shutdown "; Description = "System Halt" }
    @{ Pattern = "Restart-Computer"; Description = "System Reboot" }
)

Write-Host "`n[SAFETY MANIFEST LOADED]" -ForegroundColor Yellow
$SafetyTable | Out-String | Write-Host -ForegroundColor Gray

# --- TOOLS DEFINITIONS (The "Missing" Piece) ---
$tools = @(
    @{ 
        type = "function"
        function = @{ 
            name = "see_screen"
            description = "Takes a screenshot and uses the vision model to describe what is currently visible on Sammy's monitor."
        }
    },
    @{ 
        type = "function"
        function = @{ 
            name = "execute_command"
            description = "Runs a PowerShell command to manage files, folders, or system settings."
            parameters = @{ 
                type = "object"
                properties = @{ command = @{ type = "string"; description = "The PowerShell command to run." } }
                required = @("command")
            }
        } 
    },
    @{ 
        type = "function"
        function = @{ 
            name = "focus_window"
            description = "Brings a specific window to the foreground so keystrokes can be sent to it."
            parameters = @{ 
                type = "object"
                properties = @{ title = @{ type = "string"; description = "The title of the window to focus (e.g., 'Notepad')." } }
                required = @("title")
            }
        } 
    },
    @{ 
        type = "function"
        function = @{ 
            name = "take_action"
            description = "Sends keystrokes to the currently focused window."
            parameters = @{ 
                type = "object"
                properties = @{ keys = @{ type = "string"; description = "The keys to send (e.g., 'Hello{ENTER}', '^s' for save)." } }
                required = @("keys")
            }
        } 
    },
    @{ 
        type = "function"
        function = @{ 
            name = "wait_timer"
            description = "Pauses execution for a set duration."
            parameters = @{ 
                type = "object"
                properties = @{ seconds = @{ type = "integer"; description = "Number of seconds to wait." } }
                required = @("seconds")
            }
        } 
    }
)

# --- IMPLEMENTATIONS ---

function Get-ScreenDescription {
    Write-Host "[Eyes] Capturing screen..." -ForegroundColor Yellow
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap($screen.Width, $screen.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bmp)
    $graphics.CopyFromScreen($screen.Location, [System.Drawing.Point]::Empty, $screen.Size)
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $base64Image = [Convert]::ToBase64String($ms.ToArray())
    $graphics.Dispose(); $bmp.Dispose(); $ms.Dispose()

    $body = @{ model = $VISION_MODEL; prompt = "List all open windows and their titles exactly."; stream = $false; images = @($base64Image) } | ConvertTo-Json
    return (Invoke-RestMethod -Uri "$OLLAMA_BASE/api/generate" -Method Post -Body $body -ContentType "application/json").response
}

function Execute-SafeCommand($command) {
    foreach ($row in $SafetyTable) {
        if ($command -like "*$($row.Pattern)*") {
            Write-Host "`n[!] SAFETY VIOLATION: $($row.Description)" -ForegroundColor Red
            if ((Read-Host "Authorize? (y/n)") -ne "y") { return "Blocked." }
        }
    }
    Write-Host "[Shell] Running: $command" -ForegroundColor Cyan
    try { $res = Invoke-Expression $command | Out-String; return if ([string]::IsNullOrWhiteSpace($res)) { "Success." } else { $res } } 
    catch { return "Error: $($_.Exception.Message)" }
}

# --- REPL ENGINE ---
$global:ChatHistory = @(@{ role = "system"; content = "You are Sammy's autonomous assistant. You MUST use tools for all actions. If you aren't sure what is on screen, use see_screen." })

function Start-AgentREPL {
    Write-Host "`n--- REPL ACTIVE ---" -ForegroundColor Blue
    while ($true) {
        $userInput = Read-Host "`nREPL >"
        if ($userInput -eq "exit") { break }
        if ($userInput -eq "clear") { $global:ChatHistory = $global:ChatHistory[0]; continue }
        $global:ChatHistory += @{ role = "user"; content = $userInput }

        $thinking = $true
        while ($thinking) {
            $jsonBody = @{ model = $CONTROLLER_MODEL; messages = $global:ChatHistory; tools = $tools } | ConvertTo-Json -Depth 10
            $resp = Invoke-RestMethod -Uri "$OLLAMA_BASE/v1/chat/completions" -Method Post -Body $jsonBody -ContentType "application/json"
            $msg = $resp.choices[0].message
            
            if ($msg.content) { Write-Host "`n[Agent]: $($msg.content)" -ForegroundColor Green }
            
            if ($msg.tool_calls) {
                foreach ($t in $msg.tool_calls) {
                    $args = $t.function.arguments | ConvertFrom-Json
                    $out = switch ($t.function.name) {
                        "see_screen"      { Get-ScreenDescription }
                        "execute_command" { Execute-SafeCommand $args.command }
                        "focus_window"    { $WshShell.AppActivate($args.title); "Focused $($args.title)" }
                        "take_action"     { [System.Windows.Forms.SendKeys]::SendWait($args.keys); "Typed." }
                        "wait_timer"      { Write-Host "Waiting $($args.seconds)s..."; Start-Sleep -Seconds $args.seconds; "Done." }
                    }
                    $global:ChatHistory += $msg
                    $global:ChatHistory += @{ role = "tool"; tool_call_id = $t.id; name = $t.function.name; content = $out }
                }
            } else { $thinking = $false }
        }
    }
}

Start-AgentREPL

