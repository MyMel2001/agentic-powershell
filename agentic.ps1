Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$WshShell = New-Object -ComObject WScript.Shell

# --- CONFIG ---
$CONTROLLER_MODEL = "gemini-3-flash-preview:cloud"
$VISION_MODEL     = "ministral-3:14b-cloud"
$OLLAMA_BASE      = "http://192.168.50.135:11434"

# --- SAFETY SETTINGS ---
$DANGEROUS_PATTERNS = @("rm ", "del ", "format ", "Remove-Item", "Stop-Process", "Restart-Computer", "shutdown ")

# --- GLOBAL MEMORY ---
$global:ChatHistory = @(
    @{ role = "system"; content = "You are an autonomous Windows Agent. Use 'wait_timer' if you need to pause between actions. Use 'see_screen' to verify window states." }
)

# --- NEW TOOL: WAIT TIMER ---
function Start-WaitTimer($seconds) {
    Write-Host "[Timer] Waiting for $seconds seconds..." -ForegroundColor Yellow
    for ($i = $seconds; $i -gt 0; $i--) {
        Write-Progress -Activity "Agent is waiting..." -Status "$i seconds remaining" -PercentComplete (($i / $seconds) * 100)
        Start-Sleep -Seconds 1
    }
    return "Wait completed."
}

# --- CORE TOOLS ---
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

    $body = @{ model = $VISION_MODEL; prompt = "What windows are open? List titles."; stream = $false; images = @($base64Image) } | ConvertTo-Json
    return (Invoke-RestMethod -Uri "$OLLAMA_BASE/api/generate" -Method Post -Body $body -ContentType "application/json").response
}

function Execute-SafeCommand($command) {
    foreach ($p in $DANGEROUS_PATTERNS) { 
        if ($command -like "*$p*") { 
            Write-Host "`n⚠️  SAFETY TRIGGERED: $command" -ForegroundColor Red
            if ((Read-Host "Allow? (y/n)") -ne "y") { return "Blocked by user." }
        } 
    }
    Write-Host "[Shell] Running: $command" -ForegroundColor Cyan
    try { return (Invoke-Expression $command | Out-String) } catch { return "Error: $($_.Exception.Message)" }
}

# --- UPDATED TOOL DEFINITIONS ---
$tools = @(
    @{ type = "function"; function = @{ name = "see_screen"; description = "Visual check of desktop." } },
    @{ 
        type = "function"; function = @{ 
            name = "wait_timer"
            description = "Pause execution for a set number of seconds."
            parameters = @{ 
                type = "object"
                properties = @{ seconds = @{ type = "integer"; description = "Time to wait in seconds" } }
                required = @("seconds")
            }
        } 
    },
    @{ 
        type = "function"; function = @{ 
            name = "execute_command"; description = "Run PowerShell commands.";
            parameters = @{ 
                type = "object"
                properties = @{ command = @{ type = "string"; description = "Command string" } }
                required = @("command")
            }
        } 
    },
    @{ 
        type = "function"; function = @{ 
            name = "focus_window"; description = "Bring app to front.";
            parameters = @{ 
                type = "object"
                properties = @{ title = @{ type = "string"; description = "Window title" } }
                required = @("title")
            }
        } 
    },
    @{ 
        type = "function"; function = @{ 
            name = "take_action"; description = "Send keystrokes.";
            parameters = @{ 
                type = "object"
                properties = @{ keys = @{ type = "string"; description = "Keys to type" } }
                required = @("keys")
            }
        } 
    }
)

# --- REPL ENGINE ---
function Start-AgentREPL {
    Write-Host "`n--- Sammy's AI REPL (With Timer) ---" -ForegroundColor Blue
    while ($true) {
        $userInput = Read-Host "`nREPL >"
        if ($userInput -eq "exit") { break }
        if ($userInput -eq "clear") { $global:ChatHistory = $global:ChatHistory[0]; continue }
        
        $global:ChatHistory += @{ role = "user"; content = $userInput }

        while ($true) {
            $jsonBody = @{ model = $CONTROLLER_MODEL; messages = $global:ChatHistory; tools = $tools } | ConvertTo-Json -Depth 10
            try {
                $resp = Invoke-RestMethod -Uri "$OLLAMA_BASE/v1/chat/completions" -Method Post -Body $jsonBody -ContentType "application/json"
                $msg = $resp.choices[0].message
            } catch { break }
            
            if (-not $msg.tool_calls) {
                Write-Host "`n[Agent]: $($msg.content)" -ForegroundColor Green
                $global:ChatHistory += $msg
                break
            }

            foreach ($tool in $msg.tool_calls) {
                $args = $tool.function.arguments | ConvertFrom-Json
                $output = switch ($tool.function.name) {
                    "see_screen"      { Get-ScreenDescription }
                    "wait_timer"      { Start-WaitTimer -seconds $args.seconds }
                    "execute_command" { Execute-SafeCommand -command $args.command }
                    "focus_window"    { $WshShell.AppActivate($args.title); "Focused" }
                    "take_action"     { [System.Windows.Forms.SendKeys]::SendWait($args.keys); "Sent." }
                }
                $global:ChatHistory += $msg
                $global:ChatHistory += @{ role = "tool"; tool_call_id = $tool.id; name = $tool.function.name; content = $output }
            }
        }
    }
}

Start-AgentREPL

