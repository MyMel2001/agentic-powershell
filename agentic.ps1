Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- CONFIGURATION ---
$CONTROLLER_MODEL = "gemini-3-flash-preview:cloud"
$VISION_MODEL     = "ministral-3:14b-cloud"
$OLLAMA_URL       = "http://192.168.50.135:11434/api"
$WshShell         = New-Object -ComObject WScript.Shell

# --- SAFETY SETTINGS ---
$DANGEROUS_PATTERNS = @("rm ", "del ", "format ", "Remove-Item", "Stop-Process", "Restart-Computer", "shutdown")

# --- TOOL: EXECUTE COMMAND (WITH SAFETY) ---
function Execute-PowerShell($command) {
    # Check for dangerous patterns
    $isDangerous = $false
    foreach ($pattern in $DANGEROUS_PATTERNS) {
        if ($command -like "*$pattern*") { $isDangerous = $true; break }
    }

    if ($isDangerous) {
        Write-Host "`n⚠️  SAFETY WARNING: Agent wants to run a potentially dangerous command:" -ForegroundColor Red
        Write-Host "> $command" -ForegroundColor Yellow
        $choice = Read-Host "Allow this execution? (y/n)"
        if ($choice -ne "y") { return "User blocked execution for safety reasons." }
    }

    Write-Host "[Shell] Executing: $command" -ForegroundColor Cyan
    try {
        $result = Invoke-Expression $command | Out-String
        return if ([string]::IsNullOrWhiteSpace($result)) { "Done." } else { $result }
    } catch {
        return "Error: $($_.Exception.Message)"
    }
}

# --- TOOL: FOCUS WINDOW ---
function Focus-Window($windowTitle) {
    # Try to find a process that matches the title first for better accuracy
    $proc = Get-Process | Where-Object { $_.MainWindowTitle -like "*$windowTitle*" } | Select-Object -First 1
    if ($proc) {
        $WshShell.AppActivate($proc.Id)
        Start-Sleep -Milliseconds 500
        return "Focused window associated with process: $($proc.ProcessName)"
    }
    # Fallback to title string
    $success = $WshShell.AppActivate($windowTitle)
    return "Focus attempt by title '$windowTitle' returned: $success"
}

# --- TOOL: SEE THE SCREEN ---
function Get-ScreenDescription {
    Write-Host "[Eyes] Capturing screen..." -ForegroundColor Yellow
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bitmap = New-Object System.Drawing.Bitmap($screen.Width, $screen.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($screen.Location, [System.Drawing.Point]::Empty, $screen.Size)
    
    $ms = New-Object System.IO.MemoryStream
    $bitmap.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $base64Image = [Convert]::ToBase64String($ms.ToArray())
    
    $graphics.Dispose(); $bitmap.Dispose(); $ms.Dispose()

    $body = @{
        model = $VISION_MODEL
        prompt = "Identify all open window titles. Be specific. If there is a text editor or terminal open, name it."
        stream = $false
        images = @($base64Image)
    } | ConvertTo-Json

    $res = Invoke-RestMethod -Uri "$OLLAMA_URL/generate" -Method Post -Body $body -ContentType "application/json"
    return $res.response
}

# --- TOOLSET DEFINITION ---
$tools = @(
    @{ type = "function"; function = @{ name = "see_screen"; description = "Visual check of desktop." } },
    @{ 
        type = "function"; 
        function = @{ 
            name = "execute_command"; 
            description = "Run PowerShell commands.";
            parameters = @{ type = "object"; properties = @{ command = @{ type = "string" } }; required = @("command") }
        } 
    },
    @{ 
        type = "function"; 
        function = @{ 
            name = "focus_window"; 
            description = "Bring a window to front.";
            parameters = @{ type = "object"; properties = @{ title = @{ type = "string" } }; required = @("title") }
        } 
    },
    @{ 
        type = "function"; 
        function = @{ 
            name = "take_ui_action"; 
            description = "Send keystrokes.";
            parameters = @{ type = "object"; properties = @{ keys = @{ type = "string" } }; required = @("keys") }
        } 
    }
)

# --- AGENT LOOP ---
function Invoke-Agent($query) {
    $history = @(@{ role = "user"; content = $query })
    Write-Host "`n--- Agent Started ---" -ForegroundColor Blue

    while ($true) {
        $body = @{ model = $CONTROLLER_MODEL; messages = $history; tools = $tools } | ConvertTo-Json -Depth 10
        $resp = Invoke-RestMethod -Uri "$OLLAMA_URL/v1/chat/completions" -Method Post -Body $body -ContentType "application/json"
        $msg = $resp.choices[0].message
        
        if (-not $msg.tool_calls) {
            Write-Host "`n[Agent]: $($msg.content)" -ForegroundColor White
            break
        }

        foreach ($toolCall in $msg.tool_calls) {
            $name = $toolCall.function.name
            $args = $toolCall.function.arguments | ConvertFrom-Json
            
            $result = switch ($name) {
                "see_screen"      { Get-ScreenDescription }
                "execute_command" { Execute-PowerShell -command $args.command }
                "focus_window"    { Focus-Window -windowTitle $args.title }
                "take_ui_action"  { [System.Windows.Forms.SendKeys]::SendWait($args.keys); "Keys sent." }
            }

            $history += $msg
            $history += @{ role = "tool"; tool_call_id = $toolCall.id; name = $name; content = $result }
        }
    }
}
