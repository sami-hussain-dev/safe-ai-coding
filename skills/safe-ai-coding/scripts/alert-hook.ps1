# alert-hook.ps1 - Windows part of the safe-ai-coding alerts, run by Claude Code as a
# hook. When Claude Code asks for a permission (PermissionRequest) or asks a question
# (PreToolUse on AskUserQuestion), it plays a sound until the question is answered.
# When the editor is not the window in front, it also shows a popup with the same
# question, from which the user can answer. Installed by alerts-setup.pl.
#
# Input:  the hook's JSON on stdin.
# Output: a decision as JSON, only when the user answered in the popup. Otherwise
#         nothing, so Claude Code's own prompt stays. Closing the popup, or its
#         time limit, never decides anything.
# Settings: <claude config dir>\safe-ai-alerts.json (README: "Alerts"). Problems are
#         written to safe-ai-alerts.log in the same folder; the hook never fails.
#
# Usage (Claude Code runs the first form):
#   powershell -NoProfile -STA -ExecutionPolicy Bypass -File alert-hook.ps1
#   alert-hook.ps1 -Test permission|question     sample popup; prints the JSON it would return
#   alert-hook.ps1 -Snapshot <file.png> [-Test question]   renders the sample popup to a PNG
#   alert-hook.ps1 -SoundTest                    plays the chosen sound once
#   alert-hook.ps1 -SoundOnly -Transcript <path> -From <bytes>   background sound (started by the hook)
param([switch]$SoundOnly, [switch]$SoundTest, [string]$Transcript = '', [long]$From = -1, [string]$Test = '', [string]$Snapshot = '')

$ErrorActionPreference = 'Stop'
$ConfigDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
$LogFile = Join-Path $ConfigDir 'safe-ai-alerts.log'

function Write-Log([string]$msg) {
    try {
        if ((Test-Path -LiteralPath $LogFile) -and (Get-Item -LiteralPath $LogFile).Length -gt 200KB) { Remove-Item -LiteralPath $LogFile -Force }
        Add-Content -LiteralPath $LogFile -Value ((Get-Date -Format s) + ' ' + $msg) -Encoding UTF8
    } catch { }
}

function Get-Config {
    $c = @{ enabled = $true; sound_on = $true; sound = ''; repeat_every_seconds = 5; stop_after_seconds = 120
             popup = 'when-away'; popup_timeout_seconds = 300; focus_apps = @('Code', 'Code - Insiders', 'Cursor') }
    $path = Join-Path $ConfigDir 'safe-ai-alerts.json'
    if (Test-Path -LiteralPath $path) {
        try {
            $j = [IO.File]::ReadAllText($path) | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) { $c[$p.Name] = $p.Value }
        } catch { Write-Log "safe-ai-alerts.json ignored: $($_.Exception.Message)" }
    }
    $limits = @{ repeat_every_seconds = @(1, 60, 5); stop_after_seconds = @(5, 540, 120); popup_timeout_seconds = @(10, 540, 300) }
    foreach ($k in $limits.Keys) {
        $lo, $hi, $def = $limits[$k]
        $v = $def
        try { $v = [int]$c[$k] } catch { Write-Log "$k is not a number; using $def" }
        $c[$k] = [Math]::Min($hi, [Math]::Max($lo, $v))
    }
    if (@('when-away', 'always', 'never') -notcontains [string]$c.popup) { $c.popup = 'when-away' }
    return $c
}

# ------------------------------------------------------------------ sound

# A player is @{ kind = 'off' | 'system' | 'wav' | 'mci'; seconds = length of one play }.
# .wav files use SoundPlayer; .mp3 and .wma use Windows MCI, which needs no media player.
function New-Player($cfg) {
    if ($cfg.sound_on -eq $false -or [string]$cfg.sound -eq 'none') { return @{ kind = 'off'; seconds = 0 } }
    $file = [string]$cfg.sound
    if (-not $file) { $file = Join-Path $env:WINDIR 'Media\Windows Notify System Generic.wav' }
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        if ($cfg.sound) { Write-Log "sound file not found: $file" }
        return @{ kind = 'system'; seconds = 1 }
    }
    if ($file -match '\.wav$') {
        try { $p = New-Object System.Media.SoundPlayer $file; $p.Load(); return @{ kind = 'wav'; obj = $p; seconds = 1 } }
        catch { Write-Log "sound could not be played: $file" }
    } elseif ($file -match '\.(mp3|wma)$') {
        try {
            if (-not ('SafeAi.Mci' -as [type])) {
                Add-Type -Namespace SafeAi -Name Mci -MemberDefinition '[DllImport("winmm.dll", CharSet = CharSet.Unicode)] public static extern int mciSendString(string command, System.Text.StringBuilder result, int length, System.IntPtr callback);'
            }
            $alias = "safeai$PID"
            $sb = New-Object System.Text.StringBuilder 64
            if ([SafeAi.Mci]::mciSendString("open `"$file`" type mpegvideo alias $alias", $null, 0, [IntPtr]::Zero) -eq 0) {
                [void][SafeAi.Mci]::mciSendString("status $alias length", $sb, 64, [IntPtr]::Zero)
                $ms = 0; [void][int]::TryParse($sb.ToString(), [ref]$ms)
                return @{ kind = 'mci'; alias = $alias; seconds = [Math]::Max(1, $ms / 1000) }
            }
            Write-Log "sound could not be opened: $file"
        } catch { Write-Log "sound could not be played: $file" }
    } else { Write-Log "sound must be a .wav, .mp3 or .wma file: $file" }
    return @{ kind = 'system'; seconds = 1 }
}

function Invoke-Ding($player) {
    switch ($player.kind) {
        'wav' { $player.obj.Play() }
        'mci' { [void][SafeAi.Mci]::mciSendString("play $($player.alias) from 0", $null, 0, [IntPtr]::Zero) }
        'system' { [System.Media.SystemSounds]::Exclamation.Play() }
    }
}

# Seconds until the next ring: a long clip finishes before it starts again.
function Get-DingGap($player, $cfg) { [Math]::Max([double]$cfg.repeat_every_seconds, $player.seconds + 0.5) }

function Get-Length([string]$path) {
    if ($path -and (Test-Path -LiteralPath $path)) { return (Get-Item -LiteralPath $path).Length }
    return -1
}

# Answered = a tool result was written to the transcript after the question appeared.
function Test-Answered([string]$path, [long]$from) {
    if (-not $path -or $from -lt 0) { return $false }
    try {
        $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        try {
            if ($fs.Length -le $from) { return $false }
            $start = [Math]::Max($from, $fs.Length - 2MB)
            [void]$fs.Seek($start, 'Begin')
            $buf = New-Object byte[] ($fs.Length - $start)
            $n = $fs.Read($buf, 0, $buf.Length)
            return [Text.Encoding]::UTF8.GetString($buf, 0, $n).Contains('"tool_result"')
        } finally { $fs.Dispose() }
    } catch { return $false }
}

function Start-SoundLoop([string]$path, [long]$from, $cfg) {
    $player = New-Player $cfg
    if ($player.kind -eq 'off') { return }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $rings = 0
    while ($clock.Elapsed.TotalSeconds -lt $cfg.stop_after_seconds) {
        if (Test-Answered $path $from) { return }
        Invoke-Ding $player
        $rings++
        if ($from -lt 0 -and $rings -ge 3) { Start-Sleep -Seconds ([Math]::Ceiling($player.seconds)); return }    # nothing to watch: three rings
        $until = $clock.Elapsed.TotalSeconds + (Get-DingGap $player $cfg)
        while ($clock.Elapsed.TotalSeconds -lt $until) {
            Start-Sleep -Milliseconds 400
            if (Test-Answered $path $from) { return }
        }
    }
}

function Start-BackgroundSound([string]$path) {
    $ps = Join-Path $PSHOME 'powershell.exe'
    $argLine = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}" -SoundOnly -Transcript "{1}" -From {2}' -f $PSCommandPath, $path, (Get-Length $path)
    Start-Process -FilePath $ps -ArgumentList $argLine -WindowStyle Hidden | Out-Null
}

# ------------------------------------------------------------------ context

function Get-FrontApp {
    try {
        if (-not ('SafeAi.Win' -as [type])) {
            Add-Type -Namespace SafeAi -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
'@
        }
        $procId = [uint32]0
        [void][SafeAi.Win]::GetWindowThreadProcessId([SafeAi.Win]::GetForegroundWindow(), [ref]$procId)
        return (Get-Process -Id $procId -ErrorAction Stop).ProcessName
    } catch { return '' }
}

function Format-Plain([string]$s, [int]$max) {
    if (-not $s) { return '' }
    $s = $s -replace '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '?'
    if ($s.Length -gt $max) { $s = $s.Substring(0, $max) + ' ...' }
    return $s
}

# What Claude wrote just before this tool call (the permission block, when there is one).
function Get-ClaudeNote([string]$path) {
    try {
        if (-not $path -or -not (Test-Path -LiteralPath $path)) { return '' }
        $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        try {
            $start = [Math]::Max(0, $fs.Length - 400KB)
            [void]$fs.Seek($start, 'Begin')
            $buf = New-Object byte[] ($fs.Length - $start)
            $n = $fs.Read($buf, 0, $buf.Length)
        } finally { $fs.Dispose() }
        $lines = [Text.Encoding]::UTF8.GetString($buf, 0, $n) -split "`n"
        $texts = New-Object 'System.Collections.Generic.List[string]'
        $first = if ($start -gt 0) { 1 } else { 0 }    # the first line may be cut in half
        for ($i = $lines.Count - 1; $i -ge $first -and $i -ge $lines.Count - 80; $i--) {
            $line = $lines[$i].Trim()
            if (-not $line) { continue }
            try { $o = $line | ConvertFrom-Json } catch { continue }
            if ($o.type -eq 'user') { break }    # a tool result or a new prompt: older text is about something else
            if ($o.type -ne 'assistant' -or -not $o.message) { continue }
            $parts = @($o.message.content)
            for ($k = $parts.Count - 1; $k -ge 0; $k--) {
                if ($parts[$k].type -eq 'text' -and $parts[$k].text) { $texts.Insert(0, [string]$parts[$k].text) }
            }
        }
        $note = ($texts -join "`n`n").Trim()
        if ($note.Length -gt 1800) { $note = '... ' + $note.Substring($note.Length - 1800) }
        return Format-Plain $note 2000
    } catch { return '' }
}

function Get-Sample([string]$kind) {
    $cwd = (Get-Location).Path
    if ($kind -eq 'question') {
        $q = @{ hook_event_name = 'PreToolUse'; tool_name = 'AskUserQuestion'; cwd = $cwd; tool_input = @{ questions = @(
            @{ question = 'Which database should the migration run on?'; header = 'Database'; multiSelect = $false; options = @(
                @{ label = 'Local (Recommended)'; description = 'Your own database on this machine' },
                @{ label = 'Shared staging'; description = 'Everyone on the team sees the change at once' }) },
            @{ question = 'Which checks should run afterwards?'; header = 'Checks'; multiSelect = $true; options = @(
                @{ label = 'Unit tests'; description = 'php artisan test' },
                @{ label = 'Review scan'; description = 'safe-ai-coding diff-check' }) }) } }
        return ($q | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
    }
    $p = @{ hook_event_name = 'PermissionRequest'; tool_name = 'Bash'; cwd = $cwd
            tool_input = @{ command = 'php artisan migrate'; description = 'Run the new migration on the local database' } }
    return ($p | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
}

# ------------------------------------------------------------------ popup

function Get-Brush([string]$hex) { (New-Object Windows.Media.BrushConverter).ConvertFromString($hex) }
function Get-Edge([double]$l, [double]$t, [double]$r, [double]$b) { New-Object Windows.Thickness $l, $t, $r, $b }
$NS = 'xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"'

# Every text in the popup is set through properties, never written into XAML.
function New-Text([string]$text, [double]$size, [string]$color, [string]$weight, $margin) {
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $text; $t.FontSize = $size; $t.Foreground = Get-Brush $color
    $t.TextWrapping = 'Wrap'; $t.FontWeight = [Windows.FontWeights]::$weight; $t.Margin = $margin
    return $t
}

function New-Label([string]$text) { New-Text $text.ToUpper() 10.5 '#64748B' 'SemiBold' (Get-Edge 0 4 0 4) }

function New-Box([string]$text, [string]$bg, [string]$fg, [string]$font, [double]$maxHeight) {
    $tb = New-Object Windows.Controls.TextBox
    $tb.Text = $text; $tb.IsReadOnly = $true; $tb.TextWrapping = 'Wrap'; $tb.BorderThickness = Get-Edge 0 0 0 0
    $tb.Background = Get-Brush 'Transparent'; $tb.Foreground = Get-Brush $fg; $tb.FontSize = 12
    $tb.FontFamily = New-Object Windows.Media.FontFamily $font
    $tb.MaxHeight = $maxHeight; $tb.VerticalScrollBarVisibility = 'Auto'
    $b = New-Object Windows.Controls.Border
    $b.CornerRadius = New-Object Windows.CornerRadius 8
    $b.Background = Get-Brush $bg; $b.Padding = Get-Edge 10 8 10 8; $b.Margin = Get-Edge 0 0 0 10
    $b.Child = $tb
    return $b
}

function New-Button([string]$text, [string]$bg, [string]$fg, [string]$border) {
    $x = "<Button $NS Cursor='Hand' Padding='16,8' Margin='0,0,8,8' FontSize='13' FontWeight='SemiBold' BorderThickness='1'>" +
         "<Button.Template><ControlTemplate TargetType='Button'>" +
         "<Border x:Name='b' CornerRadius='8' Background='{TemplateBinding Background}' BorderBrush='{TemplateBinding BorderBrush}' BorderThickness='{TemplateBinding BorderThickness}' Padding='{TemplateBinding Padding}'>" +
         "<ContentPresenter HorizontalAlignment='Center' VerticalAlignment='Center'/></Border>" +
         "<ControlTemplate.Triggers><Trigger Property='IsMouseOver' Value='True'><Setter TargetName='b' Property='Opacity' Value='0.86'/></Trigger>" +
         "<Trigger Property='IsEnabled' Value='False'><Setter TargetName='b' Property='Opacity' Value='0.35'/></Trigger></ControlTemplate.Triggers>" +
         "</ControlTemplate></Button.Template></Button>"
    $b = [Windows.Markup.XamlReader]::Parse($x)
    $b.Content = $text; $b.Background = Get-Brush $bg; $b.Foreground = Get-Brush $fg; $b.BorderBrush = Get-Brush $border
    return $b
}

function New-Input([int]$lines) {
    $tb = New-Object Windows.Controls.TextBox
    $tb.FontSize = 13; $tb.Padding = Get-Edge 6 4 6 4; $tb.TextWrapping = 'Wrap'; $tb.AcceptsReturn = ($lines -gt 1)
    $tb.MinHeight = 18 * $lines + 10; $tb.BorderBrush = Get-Brush '#CBD5E1'
    return $tb
}

function New-Popup {
    $winXaml = @"
<Window $NS WindowStyle='None' AllowsTransparency='True' Background='Transparent' Topmost='True' ShowActivated='False'
        ShowInTaskbar='True' ResizeMode='NoResize' Width='490' SizeToContent='Height' FontFamily='Segoe UI' Title='Claude Code'>
  <Border x:Name='Card' Margin='16' CornerRadius='14' Background='#FFFFFF' BorderBrush='#CBD5E1' BorderThickness='1'>
    <Border.Effect><DropShadowEffect BlurRadius='26' ShadowDepth='5' Opacity='0.30' Color='#0F172A'/></Border.Effect>
    <StackPanel>
      <Border x:Name='Head' CornerRadius='13,13,0,0' Padding='18,14,14,14' Cursor='SizeAll'>
        <Border.Background>
          <LinearGradientBrush StartPoint='0,0' EndPoint='1,1'>
            <GradientStop Color='#1E1B4B' Offset='0'/><GradientStop Color='#4338CA' Offset='1'/>
          </LinearGradientBrush>
        </Border.Background>
        <DockPanel>
          <TextBlock x:Name='CloseX' DockPanel.Dock='Right' VerticalAlignment='Top' Foreground='#C7D2FE' FontSize='15' Cursor='Hand' Padding='6,0,2,4'/>
          <StackPanel>
            <TextBlock x:Name='Eyebrow' Foreground='#A5B4FC' FontSize='11' FontWeight='SemiBold'/>
            <TextBlock x:Name='Heading' Foreground='#FFFFFF' FontSize='17' FontWeight='SemiBold' TextWrapping='Wrap' Margin='0,2,0,0'/>
            <TextBlock x:Name='Sub' Foreground='#C7D2FE' FontSize='12' Margin='0,3,0,0' TextTrimming='CharacterEllipsis'/>
          </StackPanel>
        </DockPanel>
      </Border>
      <ScrollViewer MaxHeight='460' VerticalScrollBarVisibility='Auto'>
        <StackPanel x:Name='Body' Margin='18,14,18,4'/>
      </ScrollViewer>
      <WrapPanel x:Name='Actions' Margin='18,6,18,0'/>
      <StackPanel x:Name='Extra' Margin='18,0,18,0'/>
      <DockPanel Margin='18,2,18,14'>
        <TextBlock x:Name='Later' DockPanel.Dock='Right' Foreground='#4338CA' FontSize='12' Cursor='Hand' TextDecorations='Underline'/>
        <TextBlock x:Name='Foot' Foreground='#94A3B8' FontSize='11' VerticalAlignment='Center' TextWrapping='Wrap' Margin='0,0,10,0'/>
      </DockPanel>
    </StackPanel>
  </Border>
</Window>
"@
    $w = [Windows.Markup.XamlReader]::Parse($winXaml)
    $w.FindName('CloseX').Text = [string][char]0x2715
    $w.FindName('Eyebrow').Text = 'CLAUDE CODE  ' + [char]0x00B7 + '  NEEDS YOUR ANSWER'
    $w.FindName('Later').Text = 'Answer in the editor instead'
    return $w
}

function Close-Popup($result) {
    $script:result = $result
    $script:win.Close()
}

function Add-PermissionContent($in) {
    $tool = [string]$in.tool_name
    $ti = $in.tool_input
    $win.FindName('Heading').Text = "Allow ${tool}?"
    $what = ''; $intro = ''
    switch -Regex ($tool) {
        '^(Bash|PowerShell)$' { $what = [string]$ti.command; $intro = [string]$ti.description }
        '^(Write|Edit|MultiEdit)$' { $what = [string]$ti.file_path; $intro = "$tool this file" }
        '^NotebookEdit$' { $what = [string]$ti.notebook_path; $intro = 'Edit this notebook' }
        '^WebFetch$' { $what = [string]$ti.url; $intro = 'Fetch this page' }
        default { $what = ($ti | ConvertTo-Json -Depth 6 -Compress) }
    }
    $body = $win.FindName('Body')
    if ($intro) { [void]$body.Children.Add((New-Text (Format-Plain $intro 300) 13 '#0F172A' 'SemiBold' (Get-Edge 0 0 0 8))) }
    [void]$body.Children.Add((New-Label 'What it will do'))
    [void]$body.Children.Add((New-Box (Format-Plain $what 3000) '#0F172A' '#E2E8F0' 'Consolas' 150))
    if ($tool -eq 'Write' -and $ti.content) {
        [void]$body.Children.Add((New-Label 'Content (start)'))
        [void]$body.Children.Add((New-Box (Format-Plain ([string]$ti.content) 700) '#0F172A' '#E2E8F0' 'Consolas' 110))
    }
    $note = Get-ClaudeNote ([string]$in.transcript_path)
    if ($note) {
        [void]$body.Children.Add((New-Label "Claude's note"))
        [void]$body.Children.Add((New-Box $note '#F1F5F9' '#334155' 'Segoe UI' 190))
    }

    $actions = $win.FindName('Actions')
    $allow = New-Button 'Allow' '#16A34A' '#FFFFFF' '#16A34A'
    $deny = New-Button 'Deny' '#DC2626' '#FFFFFF' '#DC2626'
    $why = New-Button 'Deny with a message...' '#FFFFFF' '#334155' '#CBD5E1'
    $allow.Add_Click({ Close-Popup ([ordered]@{ behavior = 'allow' }) })
    $deny.Add_Click({ Close-Popup ([ordered]@{ behavior = 'deny'; message = 'Denied in the safe-ai-coding popup.' }) })
    $why.Add_Click({
        $this.IsEnabled = $false
        $extra = $script:win.FindName('Extra')
        [void]$extra.Children.Add((New-Label 'Message to Claude'))
        $script:reason = New-Input 3
        [void]$extra.Children.Add($script:reason)
        $send = New-Button 'Send and deny' '#DC2626' '#FFFFFF' '#DC2626'
        $send.Margin = Get-Edge 0 8 0 6; $send.HorizontalAlignment = 'Left'; $send.IsEnabled = $false
        $script:reason.Tag = $send
        $script:reason.Add_TextChanged({ $this.Tag.IsEnabled = [bool]$this.Text.Trim() })
        $send.Add_Click({ Close-Popup ([ordered]@{ behavior = 'deny'; message = $script:reason.Text.Trim() }) })
        [void]$extra.Children.Add($send)
        [void]$script:reason.Focus()
    })
    foreach ($b in @($allow, $deny, $why)) { [void]$actions.Children.Add($b) }
}

function Update-SendState {
    $ok = $true
    foreach ($it in $script:items) {
        $any = $false
        foreach ($c in $it.opts) { if ($c.IsChecked) { $any = $true } }
        if ($it.other.IsChecked -and $it.otherBox.Text.Trim()) { $any = $true }
        if (-not $any) { $ok = $false }
    }
    $script:sendBtn.IsEnabled = $ok
}

function Add-QuestionContent($in) {
    $qs = @($in.tool_input.questions)
    $win.FindName('Heading').Text = $(if ($qs.Count -gt 1) { "Claude has $($qs.Count) questions" } else { 'Claude has a question' })
    $body = $win.FindName('Body')
    $script:items = @()
    $n = 0
    foreach ($q in $qs) {
        $multi = [bool]$q.multiSelect
        if ($q.header) {
            $chip = New-Object Windows.Controls.Border
            $chip.CornerRadius = New-Object Windows.CornerRadius 6; $chip.Background = Get-Brush '#EEF2FF'
            $chip.Padding = Get-Edge 8 2 8 2; $chip.Margin = Get-Edge 0 $(if ($n) { 10 } else { 0 }) 0 4; $chip.HorizontalAlignment = 'Left'
            $chip.Child = New-Text (Format-Plain ([string]$q.header) 40) 11 '#4338CA' 'SemiBold' (Get-Edge 0 0 0 0)
            [void]$body.Children.Add($chip)
        }
        [void]$body.Children.Add((New-Text (Format-Plain ([string]$q.question) 600) 14 '#0F172A' 'SemiBold' (Get-Edge 0 0 0 4)))
        if ($multi) { [void]$body.Children.Add((New-Text 'Choose one or more' 11 '#64748B' 'Normal' (Get-Edge 0 0 0 4))) }
        $opts = @()
        foreach ($o in @($q.options)) {
            $c = if ($multi) { New-Object Windows.Controls.CheckBox } else { New-Object Windows.Controls.RadioButton }
            if (-not $multi) { $c.GroupName = "q$n" }
            $sp = New-Object Windows.Controls.StackPanel
            [void]$sp.Children.Add((New-Text (Format-Plain ([string]$o.label) 120) 13 '#0F172A' 'SemiBold' (Get-Edge 0 0 0 0)))
            if ($o.description) { [void]$sp.Children.Add((New-Text (Format-Plain ([string]$o.description) 400) 12 '#64748B' 'Normal' (Get-Edge 0 1 0 0))) }
            $c.Content = $sp; $c.Tag = [string]$o.label; $c.Margin = Get-Edge 0 4 0 4; $c.VerticalContentAlignment = 'Top'; $c.Cursor = 'Hand'
            $c.Add_Checked({ Update-SendState }); $c.Add_Unchecked({ Update-SendState })
            [void]$body.Children.Add($c)
            $opts += $c
        }
        $other = if ($multi) { New-Object Windows.Controls.CheckBox } else { New-Object Windows.Controls.RadioButton }
        if (-not $multi) { $other.GroupName = "q$n" }
        $other.Content = New-Text 'Other (write your own answer)' 13 '#0F172A' 'SemiBold' (Get-Edge 0 0 0 0)
        $other.Margin = Get-Edge 0 4 0 4; $other.Cursor = 'Hand'
        $other.Add_Checked({ Update-SendState }); $other.Add_Unchecked({ Update-SendState })
        $box = New-Input 2
        $box.Margin = Get-Edge 22 0 0 8; $box.Tag = $other
        $box.Add_TextChanged({ if ($this.Text.Trim()) { $this.Tag.IsChecked = $true }; Update-SendState })
        [void]$body.Children.Add($other)
        [void]$body.Children.Add($box)
        $script:items += @{ q = $q; opts = $opts; other = $other; otherBox = $box }
        $n++
    }
    $script:sendBtn = New-Button 'Send answer' '#4338CA' '#FFFFFF' '#4338CA'
    $script:sendBtn.IsEnabled = $false
    $script:sendBtn.Add_Click({
        $answers = [ordered]@{}
        foreach ($it in $script:items) {
            $parts = @()
            foreach ($c in $it.opts) { if ($c.IsChecked) { $parts += [string]$c.Tag } }
            if ($it.other.IsChecked -and $it.otherBox.Text.Trim()) { $parts += $it.otherBox.Text.Trim() }
            $answers[[string]$it.q.question] = ($parts -join ', ')
        }
        Close-Popup $answers
    })
    [void]$win.FindName('Actions').Children.Add($script:sendBtn)
}

function Set-PopupPosition {
    if ($script:moved) { return }
    $wa = [Windows.SystemParameters]::WorkArea
    $script:win.Left = $wa.Right - $script:win.ActualWidth
    $script:win.Top = $wa.Bottom - $script:win.ActualHeight
}

function Step-Popup {
    $e = $script:clock.Elapsed.TotalSeconds
    if ($e -ge $script:cfg.popup_timeout_seconds) { Close-Popup $null; return }
    if (Test-Answered $script:transcriptPath $script:base) { Close-Popup $null; return }
    if ($e -lt $script:cfg.stop_after_seconds -and $e -ge $script:nextDing) {
        Invoke-Ding $script:player
        $script:nextDing += Get-DingGap $script:player $script:cfg
    }
    $left = [int][Math]::Ceiling($script:cfg.popup_timeout_seconds - $e)
    $script:foot.Text = ('Closes in {0}:{1:00}. Closing decides nothing.' -f [int][Math]::Floor($left / 60), ($left % 60))
}

function Show-Popup($in, [bool]$isQuestion) {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $script:win = New-Popup
    $script:result = $null
    $script:moved = $false
    $proj = if ($in.cwd) { Split-Path -Leaf ([string]$in.cwd) } else { '' }
    $win.FindName('Sub').Text = Format-Plain $(if ($proj) { "Project: $proj" } else { 'Claude Code' }) 120
    if ($isQuestion) { Add-QuestionContent $in } else { Add-PermissionContent $in }
    $script:foot = $win.FindName('Foot')
    $script:foot.Text = ('Closes in {0}:{1:00}. Closing decides nothing.' -f [int][Math]::Floor($script:cfg.popup_timeout_seconds / 60), ($script:cfg.popup_timeout_seconds % 60))

    if ($Snapshot) {
        $card = $win.Content
        $win.Content = $null
        $card.Measure((New-Object Windows.Size 490, ([double]::PositiveInfinity)))
        $card.Arrange((New-Object Windows.Rect 0, 0, 490, $card.DesiredSize.Height))
        $card.UpdateLayout()
        $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap ([int]490), ([int][Math]::Ceiling($card.DesiredSize.Height)), 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
        $bmp.Render($card)
        $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
        $fs = [IO.File]::Create($Snapshot)
        try { $enc.Save($fs) } finally { $fs.Dispose() }
        return $null
    }

    $win.FindName('CloseX').Add_MouseLeftButtonUp({ Close-Popup $null })
    $win.FindName('Later').Add_MouseLeftButtonUp({ Close-Popup $null })
    $win.FindName('Head').Add_MouseLeftButtonDown({ $script:moved = $true; $script:win.DragMove() })
    $win.Add_Loaded({ Set-PopupPosition })
    $win.Add_SizeChanged({ Set-PopupPosition })

    $script:transcriptPath = [string]$in.transcript_path
    $script:base = Get-Length $script:transcriptPath
    $script:player = New-Player $script:cfg
    $script:clock = [Diagnostics.Stopwatch]::StartNew()
    $script:nextDing = 0
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(500)
    $timer.Add_Tick({ Step-Popup })
    Step-Popup
    $timer.Start()
    [void]$win.ShowDialog()
    $timer.Stop()
    return $script:result
}

# ------------------------------------------------------------------ main

try {
    $cfg = Get-Config
    $script:cfg = $cfg
    if ($SoundOnly) { Start-SoundLoop $Transcript $From $cfg; exit 0 }
    if ($SoundTest) {
        $player = New-Player $cfg
        if ($player.kind -eq 'off') { 'The alert sound is off.' } else { Invoke-Ding $player; Start-Sleep -Seconds ([Math]::Ceiling($player.seconds) + 1) }
        exit 0
    }

    if ($Test -or $Snapshot) {
        $in = Get-Sample $(if ($Test) { $Test } else { 'permission' })
    } else {
        try { [Console]::InputEncoding = New-Object Text.UTF8Encoding $false } catch { }
        $raw = [Console]::In.ReadToEnd()
        if (-not $raw.Trim()) { $raw = @($input) -join "`n" }
        $in = $raw.Trim().TrimStart([char]0xFEFF) | ConvertFrom-Json
        if ($cfg.enabled -eq $false) { exit 0 }
    }
    $isQuestion = ($in.hook_event_name -eq 'PreToolUse' -and $in.tool_name -eq 'AskUserQuestion')
    $isPermission = ($in.hook_event_name -eq 'PermissionRequest')
    if (-not ($isQuestion -or $isPermission)) { exit 0 }
    if ($isQuestion -and $in.tool_input.answers) { exit 0 }    # already answered elsewhere

    $front = Get-FrontApp
    $away = -not (@($cfg.focus_apps) -contains $front)
    $popup = $Test -or $Snapshot -or $cfg.popup -eq 'always' -or ($cfg.popup -eq 'when-away' -and $away)
    if (-not $popup) { Start-BackgroundSound ([string]$in.transcript_path); exit 0 }

    $answer = Show-Popup $in $isQuestion
    if ($null -eq $answer) { exit 0 }
    if ($isQuestion) {
        $updated = $in.tool_input | Select-Object *
        $updated | Add-Member -NotePropertyName answers -NotePropertyValue ([pscustomobject]$answer) -Force
        $out = [ordered]@{ hookSpecificOutput = [ordered]@{ hookEventName = 'PreToolUse'; permissionDecision = 'allow'
                           permissionDecisionReason = 'Answered in the safe-ai-coding popup'; updatedInput = $updated } }
    } else {
        $out = [ordered]@{ hookSpecificOutput = [ordered]@{ hookEventName = 'PermissionRequest'; decision = $answer } }
    }
    [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
    [Console]::Out.Write(($out | ConvertTo-Json -Depth 30 -Compress))
} catch {
    Write-Log ('error: ' + $_.Exception.Message + ' (line ' + $_.InvocationInfo.ScriptLineNumber + ')')
}
exit 0
