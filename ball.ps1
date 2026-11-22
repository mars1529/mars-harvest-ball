# 素材收割球 · 悬浮球 + 收割面板
# 单击球：抓当前微信/抖音视频链接 → 在旁边弹出小面板（选下载）
# 拖动：移动位置；右键：菜单；热键：Ctrl+Alt+G / Y / D / M
param()
$ErrorActionPreference = 'Stop'

$script:Base = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $script:Base) { $script:Base = (Get-Location).Path }
$script:LogFile = Join-Path $script:Base 'data\ball.log'
$script:StateFile = Join-Path $script:Base 'data\ball.json'
# 全新安装时 data 目录还没建，日志/状态都写不进去
try { $null = New-Item -ItemType Directory -Path (Join-Path $script:Base 'data') -Force -ErrorAction Stop } catch { }
$script:IconPath = Join-Path $script:Base 'mars.ico'
$script:MarsIconPath = Join-Path $script:Base 'mars_hud.png'

function Log([string]$m) {
    try { "[$(Get-Date -Format 'HH:mm:ss')] $m" | Out-File -LiteralPath $script:LogFile -Append -Encoding utf8 } catch { }
}
trap { Log ("TRAP: " + $_.Exception.Message + " | line " + $_.InvocationInfo.ScriptLineNumber); continue }
Log 'boot'

foreach ($asm in @('PresentationFramework', 'PresentationCore', 'WindowsBase', 'System.Windows.Forms', 'System.Drawing')) {
    try { Add-Type -AssemblyName $asm -ErrorAction Stop } catch { Log "asm FAIL: $asm" }
}

# ---------- DPI 感知（必须早于窗口创建）----------
try {
    Add-Type -Namespace WB -Name Dpi -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetProcessDpiAwarenessContext(System.IntPtr ctx);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetProcessDPIAware();
'@ -ErrorAction Stop
    $okDpi = $false
    try { $okDpi = [WB.Dpi]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch { }
    if (-not $okDpi) { try { $okDpi = [WB.Dpi]::SetProcessDPIAware() } catch { } }
} catch { Log 'dpi FAIL' }
Log 'asm+dpi ok'

$script:single = New-Object System.Threading.Mutex($false, 'Global\MarsToolBall')
if (-not $script:single.WaitOne(0)) { Log 'another instance running, exit'; exit }
Log '=== ball start ==='

# ================================================================ 悬浮球
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="120" Height="136"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" Topmost="True" ResizeMode="NoResize"
        Title="素材收割球" SnapsToDevicePixels="True" UseLayoutRounding="True"
        TextOptions.TextFormattingMode="Display" TextOptions.TextRenderingMode="ClearType"
        TextOptions.TextHintingMode="Fixed" RenderOptions.ClearTypeHint="Enabled">
  <Window.ContextMenu>
    <ContextMenu Background="#1B1216" Foreground="#DFF8FF" BorderBrush="#2A5C66" BorderThickness="1" Padding="2">
      <MenuItem x:Name="MenuGrab" Header="抓取当前视频（微信/抖音）  Ctrl+Alt+G" Padding="10,5" FontWeight="SemiBold"/>
      <MenuItem x:Name="MenuGrabWx" Header="只抓微信视频号" Padding="10,5"/>
      <MenuItem x:Name="MenuGrabDy" Header="只抓抖音  Ctrl+Alt+Y" Padding="10,5"/>
      <MenuItem x:Name="MenuClip" Header="读剪贴板链接  Ctrl+Alt+D" Padding="10,5"/>
      <MenuItem x:Name="MenuAutoClip" Header="复制链接后自动解析" Padding="10,5" IsCheckable="True" IsChecked="True"/>
      <Separator Background="#2A5C66"/>
      <MenuItem x:Name="MenuPanel" Header="展开/收起收割面板  Ctrl+Alt+M" Padding="10,5" FontWeight="SemiBold"/>
      <MenuItem x:Name="MenuOpen" Header="打开素材文件夹  Ctrl+Alt+P" Padding="10,5"/>
      <MenuItem x:Name="MenuHide" Header="隐藏到托盘" Padding="10,5"/>
      <MenuItem x:Name="MenuQuit" Header="退出" Padding="10,5"/>
    </ContextMenu>
  </Window.ContextMenu>

  <!-- 球和面板在同一个窗口里：收起时窗口只有球这么大，展开时窗口变成「面板 + 底边嵌着球」 -->
  <Grid x:Name="Root" Background="{x:Null}">

    <!-- 面板（下层，先画） -->
    <Border x:Name="PanelBox" Width="368" Height="498" Visibility="Collapsed" Panel.ZIndex="0"
            HorizontalAlignment="Left" VerticalAlignment="Top" ClipToBounds="True"
            CornerRadius="16" Background="#FF120D0E" BorderBrush="#3A4DD8F0" BorderThickness="1">
      <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="46"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
              <RowDefinition Height="48"/>
            </Grid.RowDefinitions>

            <Grid Grid.Row="0" Margin="15,0,8,0">
              <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                <Ellipse x:Name="PDot" Width="7" Height="7" Fill="#4DD8F0" VerticalAlignment="Center"/>
                <TextBlock Text="素材收割" FontFamily="Microsoft YaHei UI" FontSize="13.5" FontWeight="SemiBold"
                           Foreground="#EAF9FF" Margin="7,0,0,0" VerticalAlignment="Center"/>
                <Border x:Name="PPlatBox" Background="#1F4DD8F0" CornerRadius="3" Padding="5,1,5,2"
                        Margin="8,0,0,0" VerticalAlignment="Center" Visibility="Collapsed">
                  <TextBlock x:Name="PPlat" Text="视频号" FontFamily="Microsoft YaHei UI" FontSize="9.5" Foreground="#9FE8F7"/>
                </Border>
              </StackPanel>
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                <Border x:Name="PBtnRefresh" Width="24" Height="24" CornerRadius="6" Background="#16FFFFFF"
                        Margin="0,0,4,0" Cursor="Hand">
                  <TextBlock Text="⟳" FontSize="12" Foreground="#9FD8E4" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <Border x:Name="PBtnClose" Width="24" Height="24" CornerRadius="6" Background="#16FFFFFF" Cursor="Hand">
                  <TextBlock Text="✕" FontSize="10.5" Foreground="#9FD8E4" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
              </StackPanel>
            </Grid>

            <TextBlock x:Name="PStatus" Grid.Row="1" Margin="15,0,15,9" Text="点球抓当前视频，或按 Ctrl+Alt+G" FontFamily="Microsoft YaHei UI"
                       FontSize="11" Foreground="#7DE3F2" TextWrapping="Wrap"/>

            <Border x:Name="PCard" Grid.Row="2" Margin="12,0,12,8" Background="#1F1B1216" BorderBrush="#2E4DD8F0"
                    BorderThickness="1" CornerRadius="10" Padding="10" Visibility="Collapsed">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Border Grid.Column="0" Width="88" Height="88" CornerRadius="8" Background="#22120D10" VerticalAlignment="Top">
                  <Image x:Name="PCover" Width="88" Height="88" Stretch="UniformToFill">
                    <Image.Clip>
                      <RectangleGeometry Rect="0,0,88,88" RadiusX="8" RadiusY="8"/>
                    </Image.Clip>
                  </Image>
                </Border>
                <StackPanel Grid.Column="1" Margin="10,0,0,0">
                  <TextBlock x:Name="PAuthor" FontFamily="Microsoft YaHei UI" FontSize="12" FontWeight="SemiBold"
                             Foreground="#EAF9FF" TextTrimming="CharacterEllipsis"/>
                  <TextBlock x:Name="PDesc" Margin="0,4,0,0" FontFamily="Microsoft YaHei UI" FontSize="11"
                             Foreground="#A8C4CE" TextWrapping="Wrap" MaxHeight="46" TextTrimming="CharacterEllipsis"/>
                  <StackPanel x:Name="PCardBtns" Orientation="Horizontal" Margin="0,10,0,0"/>
                </StackPanel>
              </Grid>
            </Border>

            <Grid Grid.Row="3" Margin="12,0,12,0">
              <Grid.RowDefinitions>
                <RowDefinition Height="22"/>
                <RowDefinition Height="*"/>
              </Grid.RowDefinitions>
              <TextBlock x:Name="PListTitle" Grid.Row="0" Text="最近抓取" FontFamily="Microsoft YaHei UI"
                         FontSize="10.5" Foreground="#6E8B96" VerticalAlignment="Center"/>
              <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
                <StackPanel x:Name="PList"/>
              </ScrollViewer>
            </Grid>

            <Grid Grid.Row="4" Margin="14,6,14,10">
              <Border x:Name="PBtnOpen" Background="#1A4DD8F0" BorderBrush="#3A4DD8F0" BorderThickness="1"
                      CornerRadius="8" Height="32" Width="120" HorizontalAlignment="Left" Cursor="Hand">
                <TextBlock Text="素材文件夹" FontFamily="Microsoft YaHei UI" FontSize="11.5" FontWeight="SemiBold"
                           Foreground="#9FE8F7" HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <Border x:Name="PBtnFolder" Background="#12FFFFFF" BorderBrush="#22FFFFFF" BorderThickness="1"
                      CornerRadius="8" Height="32" Width="96" HorizontalAlignment="Right" Cursor="Hand">
                <TextBlock Text="素材文件夹" FontFamily="Microsoft YaHei UI" FontSize="11.5"
                           Foreground="#8FA9B4" HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
            </Grid>
          </Grid>
    </Border>
    <!-- 球（上层）：展开时压在面板底边正中，上半在面板里、下半露在外面 -->
    <Grid x:Name="BallHost" Width="120" Height="136" Panel.ZIndex="10"
          HorizontalAlignment="Left" VerticalAlignment="Top">
      <Grid.RowDefinitions>
        <RowDefinition Height="92"/>
        <RowDefinition Height="28"/>
        <RowDefinition Height="16"/>
      </Grid.RowDefinitions>

      <Grid x:Name="Ball" Grid.Row="0" Width="84" Height="84" HorizontalAlignment="Center"
            VerticalAlignment="Center" RenderTransformOrigin="0.5,0.5" Background="#01000000">
        <Ellipse x:Name="Glow" Width="78" Height="78" Stroke="#4DD8F0" StrokeThickness="6" Opacity="0.2">
          <Ellipse.Effect><BlurEffect Radius="15"/></Ellipse.Effect>
        </Ellipse>
        <Ellipse Width="80" Height="80" StrokeThickness="0.9" Opacity="0.85">
          <Ellipse.Stroke>
            <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
              <GradientStop Color="#4DD8F0" Offset="0"/>
              <GradientStop Color="#FF8A4C" Offset="0.5"/>
              <GradientStop Color="#4DD8F0" Offset="1"/>
            </LinearGradientBrush>
          </Ellipse.Stroke>
        </Ellipse>
        <Path x:Name="Arc" Data="M 33.4,7.5 A 35.5,35.5 0 0 1 76.5,33.4"
              Stroke="#4DD8F0" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round">
          <Path.Effect><DropShadowEffect Color="#4DD8F0" BlurRadius="8" ShadowDepth="0" Opacity="0.95"/></Path.Effect>
          <Path.RenderTransform>
            <RotateTransform x:Name="ArcRotate" CenterX="42" CenterY="42" Angle="0"/>
          </Path.RenderTransform>
        </Path>
        <Ellipse Width="66" Height="66">
          <Ellipse.Fill>
            <RadialGradientBrush GradientOrigin="0.35,0.3">
              <GradientStop Color="#2C1A18" Offset="0"/>
              <GradientStop Color="#1A1113" Offset="0.72"/>
              <GradientStop Color="#120D10" Offset="1"/>
            </RadialGradientBrush>
          </Ellipse.Fill>
        </Ellipse>
        <Ellipse x:Name="InnerStroke" Width="66" Height="66" Stroke="#4DD8F0" StrokeThickness="0.8" Opacity="0.45"/>
        <Ellipse Width="56" Height="56" Stroke="#4DD8F0" StrokeThickness="0.7" StrokeDashArray="1.4 4.5" Opacity="0.4"/>
        <Image x:Name="MarsIcon" Width="70" Height="70" Stretch="Uniform" IsHitTestVisible="False"
               RenderOptions.BitmapScalingMode="HighQuality">
          <Image.Effect><DropShadowEffect Color="#4DD8F0" BlurRadius="8" ShadowDepth="0" Opacity="0.28"/></Image.Effect>
        </Image>
      </Grid>

      <Border x:Name="Toast" Grid.Row="1" Margin="4,0,4,0" CornerRadius="7"
              Background="#E61B1216" BorderBrush="#804DD8F0" BorderThickness="1"
              Opacity="0" Visibility="Collapsed" VerticalAlignment="Center">
        <TextBlock x:Name="ToastText" Margin="6,3" FontSize="10.5" FontFamily="Microsoft YaHei UI"
                   Foreground="#DFF8FF" TextWrapping="Wrap" TextAlignment="Center" LineHeight="13"/>
      </Border>

      <TextBlock x:Name="Status" Grid.Row="1" Text="待命" FontSize="11" FontFamily="Microsoft YaHei UI"
                 FontWeight="SemiBold" Foreground="#7DE3F2" HorizontalAlignment="Center"
                 VerticalAlignment="Center" TextAlignment="Center"/>

      <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center">
        <Ellipse x:Name="Dot" Width="5" Height="5" Fill="#4DD8F0">
          <Ellipse.Effect><BlurEffect Radius="4"/></Ellipse.Effect>
        </Ellipse>
        <TextBlock x:Name="DotText" Text="MARS" FontSize="7.5" FontFamily="Consolas"
                   Foreground="#4DD8F0" Margin="3,0,0,0" VerticalAlignment="Center"/>
      </StackPanel>
    </Grid>

  </Grid>
</Window>
'@


$win = $null
try {
    $xmlDoc = New-Object System.Xml.XmlDocument
    $xmlDoc.LoadXml($xaml)
    $rdr = New-Object System.Xml.XmlNodeReader($xmlDoc)
    $win = [Windows.Markup.XamlReader]::Load($rdr)
} catch {
    Log ('xaml FAIL: ' + $_.Exception.Message); exit
}

$Root = $win.FindName('Root')
$Ball = $win.FindName('Ball')
$MarsIcon = $win.FindName('MarsIcon')
try {
    if ($MarsIcon -and (Test-Path -LiteralPath $script:MarsIconPath)) {
        $mi = New-Object System.Windows.Media.Imaging.BitmapImage
        $mi.BeginInit(); $mi.CacheOption = 'OnLoad'
        $mi.UriSource = New-Object System.Uri($script:MarsIconPath, [System.UriKind]::Absolute)
        $mi.EndInit(); $mi.Freeze()
        $MarsIcon.Source = $mi
    }
} catch { Log 'mars icon FAIL' }

$Toast = $win.FindName('Toast')
$ToastText = $win.FindName('ToastText')
$Status = $win.FindName('Status')
$Dot = $win.FindName('Dot')
$DotText = $win.FindName('DotText')
$Glow = $win.FindName('Glow')
$InnerStroke = $win.FindName('InnerStroke')
$Arc = $win.FindName('Arc')
$ArcRotate = $win.FindName('ArcRotate')
$MenuGrab = $win.FindName('MenuGrab')
$MenuGrabWx = $win.FindName('MenuGrabWx')
$MenuGrabDy = $win.FindName('MenuGrabDy')
$MenuClip = $win.FindName('MenuClip')
$MenuAutoClip = $win.FindName('MenuAutoClip')
$MenuPanel = $win.FindName('MenuPanel')
$MenuOpen = $win.FindName('MenuOpen')
$MenuHide = $win.FindName('MenuHide')
$MenuQuit = $win.FindName('MenuQuit')

$script:Conv = New-Object System.Windows.Media.BrushConverter
function Brush([string]$hex) { return $script:Conv.ConvertFromString($hex) }

$script:HoverScale = New-Object System.Windows.Media.ScaleTransform(1.0, 1.0)
$Ball.RenderTransform = $script:HoverScale

$script:FadeIn = New-Object System.Windows.Media.Animation.DoubleAnimation(0.0, 1.0, [TimeSpan]::FromMilliseconds(140))
$script:FadeOut = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, 0.0, [TimeSpan]::FromMilliseconds(320))
$script:FadeOut.Add_Completed({ $Toast.Visibility = 'Collapsed' })

function Set-Spin([double]$sec) {
    $an = New-Object System.Windows.Media.Animation.DoubleAnimation(0.0, 360.0, [TimeSpan]::FromSeconds($sec))
    $an.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $ArcRotate.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $an)
}

function Set-Visual([string]$state, [string]$text) {
    $c = '#4DD8F0'
    switch ($state) {
        'busy'  { $c = '#FFB45C'; Set-Spin 1.1; $Glow.Opacity = 0.3 }
        'done'  { $c = '#6EE7B7'; Set-Spin 20.0; $Glow.Opacity = 0.26 }
        'error' { $c = '#FF7B7B'; Set-Spin 30.0; $Glow.Opacity = 0.3 }
        'ready' { $c = '#FF8A4C'; Set-Spin 8.0; $Glow.Opacity = 0.26 }
        default { $c = '#4DD8F0'; Set-Spin 11.0; $Glow.Opacity = 0.2 }
    }
    $b = Brush $c
    $Glow.Stroke = $b
    $InnerStroke.Stroke = $b
    $Arc.Stroke = $b
    $Dot.Fill = $b
    $DotText.Foreground = $b
    if ($text) { $Status.Text = $text; $Status.Foreground = $b }
}

function Show-Toast([string]$text, [string]$color) {
    $t = ($text -replace '\s+', ' ').Trim()
    if ($t.Length -gt 46) { $t = $t.Substring(0, 45) + '…' }
    $ToastText.Text = $t
    $ToastText.Foreground = Brush $color
    $Status.Visibility = 'Collapsed'
    $Toast.Visibility = 'Visible'
    $Toast.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $script:FadeIn)
    $script:toastTimer.Stop(); $script:toastTimer.Start()
}

$script:toastTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:toastTimer.Interval = [TimeSpan]::FromSeconds(3.4)
$script:toastTimer.Add_Tick({
    $script:toastTimer.Stop()
    $Toast.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $script:FadeOut)
    $Status.Visibility = 'Visible'
})

# ---------- 位置 ----------
function Clamp-Pos {
    $wa = [System.Windows.SystemParameters]::WorkArea
    # 用「应该多大」而不是 ActualWidth：改尺寸的瞬间 ActualWidth 还是旧值，会把窗口算到屏幕外
    $w = 120.0; $h = 136.0
    if ($script:PanelOpen) { $w = [double]$script:PanW; $h = [double]$script:WinH }
    # 至少留 60x46 露在屏幕里，拖不丢
    if ($win.Left -gt ($wa.Right - 60)) { $win.Left = $wa.Right - 60 }
    if ($win.Top -gt ($wa.Bottom - 46)) { $win.Top = $wa.Bottom - 46 }
    if ($win.Left -lt ($wa.Left - ($w - 60))) { $win.Left = $wa.Left - ($w - 60) }
    if ($win.Top -lt ($wa.Top - ($h - 46))) { $win.Top = $wa.Top - ($h - 46) }
}

function Save-State {
    try {
        $bx = [double]$win.Left
        $by = [double]$win.Top
        if ($script:PanelOpen) { $bx = $win.Left + $script:BallX; $by = $win.Top + $script:BallY }
        @{ x = [int]$bx; y = [int]$by; autoclip = [bool]$script:AutoClip } | ConvertTo-Json |
            Set-Content -LiteralPath $script:StateFile -Encoding UTF8
    } catch { }
}

$wa = [System.Windows.SystemParameters]::WorkArea
$script:StartX = $wa.Right - 150
$script:StartY = $wa.Bottom - 240
$script:AutoClip = $true
if (Test-Path -LiteralPath $script:StateFile) {
    try {
        $st = Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json
        if ($null -ne $st.x) { $script:StartX = [int]$st.x }
        if ($null -ne $st.y) { $script:StartY = [int]$st.y }
        if ($null -ne $st.autoclip) { $script:AutoClip = [bool]$st.autoclip }
    } catch { }
}
$win.Left = $script:StartX
$win.Top = $script:StartY
# 球的「自由位置」：面板收起时球停这里；面板展开时球会被嵌到面板底部中间
$script:PanelOpen = $false

# ================================================================ 独立收割面板
$script:Jobs = @{}
$script:Busy = $false
$script:DlBusy = $false
$script:Clips = @()
$script:CurLink = ''
$script:CurInfo = $null
$script:DoneMap = @{}
$script:LastClipText = ''
$script:Quitting = $false

function Get-Port {
    try { return [int]((Get-Content -LiteralPath (Join-Path $script:Base 'data\port.txt') -Raw).Trim()) } catch { return 8765 }
}

function New-Chip([string]$text, [string]$bg, [string]$fg, [string]$bd = '#00000000', [double]$fs = 11.5) {
    $b = New-Object System.Windows.Controls.Border
    $b.Background = Brush $bg
    $b.BorderBrush = Brush $bd
    $b.BorderThickness = New-Object System.Windows.Thickness(1)
    $b.CornerRadius = New-Object System.Windows.CornerRadius(7)
    $b.Padding = New-Object System.Windows.Thickness(11, 5, 11, 6)
    $b.Cursor = [System.Windows.Input.Cursors]::Hand
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $text
    $t.FontSize = $fs
    $t.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei UI')
    $t.FontWeight = [System.Windows.FontWeights]::SemiBold
    $t.Foreground = Brush $fg
    $t.TextAlignment = 'Center'
    $t.VerticalAlignment = 'Center'
    $b.Child = $t
    $b.Add_MouseEnter({ param($s, $e) $s.Opacity = 0.82 })
    $b.Add_MouseLeave({ param($s, $e) $s.Opacity = 1.0 })
    return $b
}

function Load-Bmp([string]$uri) {
    $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
    $bmp.BeginInit()
    $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bmp.CreateOptions = [System.Windows.Media.Imaging.BitmapCreateOptions]::IgnoreImageCache
    $bmp.UriSource = New-Object System.Uri($uri, [System.UriKind]::Absolute)
    $bmp.EndInit()
    return $bmp
}

function Set-PanelStatus([string]$text, [string]$color = '#7DE3F2') {
    try {
        $PStatus.Text = $text
        $PStatus.Foreground = Brush $color
        $PDot.Fill = Brush $color
    } catch { }
}

function Set-PanelCover([string]$cover, [string]$link) {
    try {
        if ($cover -and (Test-Path -LiteralPath $cover)) {
            $PCover.Source = Load-Bmp $cover
            return
        }
        if ($link) {
            $u = 'http://127.0.0.1:' + (Get-Port) + '/api/harvest/cover?link=' + [uri]::EscapeDataString($link)
            $PCover.Source = Load-Bmp $u
            return
        }
        $PCover.Source = $null
    } catch { $PCover.Source = $null }
}

function Copy-Link([string]$link) {
    if (-not $link) { Set-PanelStatus '这条没有链接' '#FF7B7B'; return }
    for ($i = 0; $i -lt 5; $i++) {
        try {
            [System.Windows.Clipboard]::SetText($link)
            # 自己写进去的链接不算「用户新复制」，否则剪贴板监听会再解析一遍
            try { $script:ClipSeq = [WB.Clip]::GetClipboardSequenceNumber() } catch { }
            try { $script:LastClipText = $link } catch { }
            Set-PanelStatus '链接已复制到剪贴板' '#6EE7B7'
            Show-Toast '链接已复制，可直接发给别人' '#6EE7B7'
            return
        } catch {
            # 剪贴板被别的程序占着（抖音/微信刚复制过）—— 等一下再试
            Start-Sleep -Milliseconds 120
        }
    }
    Set-PanelStatus '剪贴板被占用，复制失败，稍后重试' '#FF7B7B'
    Show-Toast '剪贴板被占用，再点一次' '#FF7B7B'
}

function Render-CardBtns([string]$link) {
    $PCardBtns.Children.Clear()
    $dl = New-Chip '下载到素材库' '#4DD8F0' '#08161A'
    $dl.Tag = $link
    $dl.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Invoke-PanelDownload ([string]$s.Tag) })
    $null = $PCardBtns.Children.Add($dl)

    $cp = New-Chip '复制链接' '#14FFFFFF' '#9FD8E4' '#33FFFFFF'
    $cp.Margin = New-Object System.Windows.Thickness(6, 0, 0, 0)
    $cp.Tag = $link
    $cp.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Copy-Link ([string]$s.Tag) })
    $null = $PCardBtns.Children.Add($cp)

    if ($script:DoneMap.ContainsKey($link)) {
        $go = New-Chip '打开文件夹 →' '#1AFF8A4C' '#FFB98A' '#55FF8A4C'
        $go.Margin = New-Object System.Windows.Thickness(6, 0, 0, 0)
        $go.Tag = $link
        $go.Add_MouseLeftButtonUp({
            param($s, $e)
            $e.Handled = $true
            Start-Action 'folder' $script:FolderBlock @($script:Base)
        })
        $null = $PCardBtns.Children.Add($go)
    }
}

function Render-PanelCard($info) {
    if (-not $info -or -not $info.link) {
        $PCard.Visibility = 'Collapsed'
        $PPlatBox.Visibility = 'Collapsed'
        $script:CurLink = ''
        $script:CurInfo = $null
        return
    }
    $script:CurInfo = $info
    $script:CurLink = [string]$info.link
    $PCard.Visibility = 'Visible'
    $PPlatBox.Visibility = 'Visible'
    $PPlat.Text = $(if ([string]$info.platform -eq 'wx') { '视频号' } else { '抖音' })
    $PAuthor.Text = $(if ($info.author) { [string]$info.author } else { '未知作者' })
    $PDesc.Text = $(if ($info.desc) { [string]$info.desc } else { '（这条没有文案）' })
    Set-PanelCover ([string]$info.cover) ([string]$info.link)
    Render-CardBtns ([string]$info.link)
}

function Find-Clip([string]$link) {
    foreach ($c in $script:Clips) {
        if ([string]$c.link -eq $link) { return $c }
    }
    return $null
}

function Show-Clip([string]$link) {
    $hit = Find-Clip $link
    if (-not $hit) { return }
    Render-PanelCard @{ link = $link; author = $hit.author; desc = $hit.desc; platform = $hit.platform; cover = '' }
    Render-PanelList
}

function Render-PanelList {
    $PList.Children.Clear()
    $items = @($script:Clips)
    if ($items.Count -eq 0) {
        $PListTitle.Text = '最近抓取'
        $empty = New-Object System.Windows.Controls.TextBlock
        $empty.Text = "还没有抓过链接`n点球或按 Ctrl+Alt+G 抓当前视频"
        $empty.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei UI')
        $empty.FontSize = 10.5
        $empty.Foreground = Brush '#5E7A85'
        $empty.TextAlignment = 'Center'
        $empty.Margin = New-Object System.Windows.Thickness(0, 14, 0, 0)
        $null = $PList.Children.Add($empty)
        return
    }
    $PListTitle.Text = '最近抓取 · ' + $items.Count + ' 条'

    foreach ($x in $items) {
        $link = [string]$x.link
        $row = New-Object System.Windows.Controls.Border
        $row.CornerRadius = New-Object System.Windows.CornerRadius(8)
        $row.Margin = New-Object System.Windows.Thickness(0, 0, 0, 4)
        $row.Padding = New-Object System.Windows.Thickness(9, 5, 6, 6)
        $row.Background = Brush $(if ($link -eq $script:CurLink) { '#1F4DD8F0' } else { '#0DFFFFFF' })
        $row.Cursor = [System.Windows.Input.Cursors]::Hand
        $row.Tag = $link

        $g = New-Object System.Windows.Controls.Grid
        $c1 = New-Object System.Windows.Controls.ColumnDefinition
        $c1.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
        $c2 = New-Object System.Windows.Controls.ColumnDefinition
        $c2.Width = [System.Windows.GridLength]::Auto
        $null = $g.ColumnDefinitions.Add($c1)
        $null = $g.ColumnDefinitions.Add($c2)

        $st = New-Object System.Windows.Controls.StackPanel
        $t1 = New-Object System.Windows.Controls.TextBlock
        $t1.Text = $(if ($x.desc) { [string]$x.desc } elseif ($x.author) { [string]$x.author } else { '（无标题）' })
        $t1.FontSize = 11
        $t1.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei UI')
        $t1.Foreground = Brush '#D6ECF4'
        $t1.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
        $t1.MaxWidth = 210
        $null = $st.Children.Add($t1)

        $bits = @()
        $bits += $(if ([string]$x.platform -eq 'wx') { '视频号' } else { '抖音' })
        if ($x.author) { $bits += [string]$x.author }
        if ($x.ts) { $bits += [string]$x.ts }
        if ($x.done) { $bits += '已入库' }
        $t2 = New-Object System.Windows.Controls.TextBlock
        $t2.Text = ($bits -join ' · ')
        $t2.FontSize = 9.5
        $t2.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei UI')
        $t2.Foreground = Brush $(if ($x.done) { '#7FD8B8' } else { '#6E8B96' })
        $t2.Margin = New-Object System.Windows.Thickness(0, 2, 0, 0)
        $t2.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
        $t2.MaxWidth = 210
        $null = $st.Children.Add($t2)
        [System.Windows.Controls.Grid]::SetColumn($st, 0)
        $null = $g.Children.Add($st)

        $hact = New-Object System.Windows.Controls.StackPanel
        $hact.Orientation = 'Horizontal'
        $hact.VerticalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetColumn($hact, 1)

        $dl = New-Chip '下载' '#1A4DD8F0' '#9FE8F7' '#2E4DD8F0' 9.5
        $dl.Padding = New-Object System.Windows.Thickness(8, 3, 8, 4)
        $dl.Tag = $link
        $dl.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Invoke-PanelDownload ([string]$s.Tag) })
        $null = $hact.Children.Add($dl)

        $rm = New-Chip '删' '#0DFFFFFF' '#6E8B96' '#1EFFFFFF' 9.5
        $rm.Padding = New-Object System.Windows.Thickness(7, 3, 7, 4)
        $rm.Margin = New-Object System.Windows.Thickness(5, 0, 0, 0)
        $rm.Tag = $link
        $rm.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Invoke-PanelDelete ([string]$s.Tag) })
        $null = $hact.Children.Add($rm)

        $null = $g.Children.Add($hact)
        $row.Child = $g
        $row.Add_MouseLeftButtonUp({ param($s, $e) Show-Clip ([string]$s.Tag) })
        $null = $PList.Children.Add($row)
    }
}

# 透明窗口改尺寸/位置后，DWM 会把旧画面留在桌面上（看着像两个面板叠着）。
# 轻微改一下透明度就能强制整窗重绘，用户看不出来。
function Repaint-Win {
    try {
        $win.Opacity = 0.985
        $win.Opacity = 1.0
        $win.InvalidateVisual()
    } catch { }
}

# ================================================================ 连体窗口（球 + 面板）
# 球和面板是同一个窗口的两个状态：
#   收起：窗口 120x136，只有球
#   展开：窗口 368x588，面板占上半 368x498，球嵌在面板底边正中（上半被面板盖住）
$script:PanW = 368
$script:PanH = 498
$script:WinH = 588
$script:BallX = 124      # 展开时球控件在窗口里的左上角
$script:BallY = 452
$script:PanelOpen = $false

function Set-PanelOpen([bool]$open) {
    if ($open -eq $script:PanelOpen) { return }
    $wa = [System.Windows.SystemParameters]::WorkArea
    if ($open) {
        # 记下球此刻在屏幕上的视觉中心，展开后让球停在原地
        $cx = [double]$win.Left + 60
        $cy = [double]$win.Top + 46
        $script:PanelOpen = $true
        $script:BallHost.Margin = New-Object System.Windows.Thickness($script:BallX, $script:BallY, 0, 0)
        $script:PanelBox.Visibility = 'Visible'
        # 展开时球只留圆环，状态文字收起来（收起后还要显示）
        foreach ($n in 'Status', 'Dot', 'DotText') {
            $el = $win.FindName($n)
            if ($el) { $el.Visibility = 'Collapsed' }
        }
        $win.Width = $script:PanW
        $win.Height = $script:WinH
        $left = $cx - 184
        $top = $cy - 498
        if ($left -lt ($wa.Left + 8)) { $left = $wa.Left + 8 }
        if ($top -lt ($wa.Top + 8)) { $top = $wa.Top + 8 }
        if (($left + $script:PanW) -gt ($wa.Right - 8)) { $left = $wa.Right - 8 - $script:PanW }
        if (($top + $script:WinH) -gt ($wa.Bottom - 8)) {
            # 底部被屏幕挡住时先保面板，把球挪到窗口里更高的位置
            $top = $wa.Bottom - 8 - $script:WinH
        }
        $win.Left = $left
        $win.Top = $top
        Clamp-Pos
        Repaint-Win
    } else {
        $cx = [double]$win.Left + $script:BallX + 60
        $cy = [double]$win.Top + $script:BallY + 46
        $script:PanelOpen = $false
        $script:PanelBox.Visibility = 'Collapsed'
        foreach ($n in 'Status', 'Dot', 'DotText') {
            $el = $win.FindName($n)
            if ($el) { $el.Visibility = 'Visible' }
        }
        $script:BallHost.Margin = New-Object System.Windows.Thickness(0, 0, 0, 0)
        $win.Width = 120
        $win.Height = 136
        $win.Left = $cx - 60
        $win.Top = $cy - 46
        Repaint-Win
        Clamp-Pos
        Save-State
    }
}

function Show-Panel {
    try {
        if (-not $script:PanelBox) { return }
        # 圆角矩形硬裁剪：窗口是透明窗口，光靠 ClipToBounds 挡不住溢出
        if (-not $script:PanelBox.Clip) {
            $cg = New-Object System.Windows.Media.RectangleGeometry
            $cg.Rect = New-Object System.Windows.Rect(0, 0, $script:PanW, $script:PanH)
            $cg.RadiusX = 16
            $cg.RadiusY = 16
            $script:PanelBox.Clip = $cg
        }
        Set-PanelOpen $true
        $win.Topmost = $false
        $win.Topmost = $true
        $null = $win.Activate()
    } catch { Log ('panel show FAIL: ' + $_.Exception.Message) }
}

function Hide-Panel {
    try { Set-PanelOpen $false } catch { }
}

# 抓取让位：窗口不挪窝，改成「鼠标穿透」（WS_EX_TRANSPARENT）
# 这样球一直看得见，微信/抖音的「分享」按钮也能正常点到，不会出现球突然消失
$script:ClickThrough = $false
if (-not ('WB.Ex' -as [type])) {
    try {
        Add-Type -Namespace WB -Name Ex -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true)]
public static extern System.IntPtr GetWindowLongPtr(System.IntPtr hWnd, int nIndex);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true)]
public static extern System.IntPtr SetWindowLongPtr(System.IntPtr hWnd, int nIndex, System.IntPtr dwNewLong);
'@ -ErrorAction Stop
    } catch { Log ('exstyle type FAIL: ' + $_.Exception.Message) }
}

function Set-ClickThrough([bool]$on) {
    try {
        if ($script:ClickThrough -eq $on) { return }
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($win)
        $h = $helper.Handle
        if ($h -eq [IntPtr]::Zero) { return }
        $GWL_EXSTYLE = -20
        $WS_EX_TRANSPARENT = 0x20
        $ex = [WB.Ex]::GetWindowLongPtr($h, $GWL_EXSTYLE).ToInt64()
        if ($on) { $ex = $ex -bor $WS_EX_TRANSPARENT } else { $ex = $ex -band (-bnot $WS_EX_TRANSPARENT) }
        [void][WB.Ex]::SetWindowLongPtr($h, $GWL_EXSTYLE, [IntPtr]$ex)
        $script:ClickThrough = $on
        Log ('click-through=' + $on)
    } catch { Log ('click-through FAIL: ' + $_.Exception.Message) }
}

# 兜底：万一抓取任务半路断了，90 秒后自动恢复可点击，不会把球变成死的
$script:ctTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:ctTimer.Interval = [TimeSpan]::FromSeconds(90)
$script:ctTimer.Add_Tick({
    $script:ctTimer.Stop()
    Set-ClickThrough $false
})

function Refresh-Clips {
    Start-Action 'clips' $script:ClipsBlock @($script:Base)
}

function Build-Panel {
    # 面板元素就在主窗口里（连体），直接取引用，不用再创建第二个窗口
    $script:PanelBox = $win.FindName('PanelBox')
    $script:BallHost = $win.FindName('BallHost')
    $script:PStatus = $win.FindName('PStatus')
    $script:PCard = $win.FindName('PCard')
    $script:PCover = $win.FindName('PCover')
    $script:PAuthor = $win.FindName('PAuthor')
    $script:PDesc = $win.FindName('PDesc')
    $script:PCardBtns = $win.FindName('PCardBtns')
    $script:PPlatBox = $win.FindName('PPlatBox')
    $script:PPlat = $win.FindName('PPlat')
    $script:PDot = $win.FindName('PDot')
    $script:PList = $win.FindName('PList')
    $script:PListTitle = $win.FindName('PListTitle')
    $script:PBtnOpen = $win.FindName('PBtnOpen')
    $script:PBtnFolder = $win.FindName('PBtnFolder')
    $script:PBtnClose = $win.FindName('PBtnClose')
    $script:PBtnRefresh = $win.FindName('PBtnRefresh')
    if (-not $script:PanelBox -or -not $script:PList) { Log 'panel elements missing'; return }

    $script:PBtnClose.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Hide-Panel })
    $script:PBtnRefresh.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Refresh-Clips; Set-PanelStatus '正在刷新列表…' })
    $script:PBtnOpen.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Start-Action 'folder' $script:FolderBlock @($script:Base) })
    $script:PBtnFolder.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Start-Action 'folder' $script:FolderBlock @($script:Base) })

    # 悬浮球必须永远置顶：一旦被别的窗口盖住，用户就点不到、看起来像消失了
    # （以前失焦就 Topmost=false，切个微信球就沉底，这是「球消失」的第二个来源）
    $win.Add_Activated({
        try { $win.Topmost = $true } catch { }
    })
    $win.Add_KeyDown({
        param($s, $e)
        if ($e.Key -eq [System.Windows.Input.Key]::Escape -and $script:PanelOpen) { Hide-Panel }
    })
    $win.Add_Closing({
        param($s, $e)
        if (-not $script:Quitting) { $e.Cancel = $true; $s.Hide() }
    })
    Log 'panel built'
}

# ================================================================ 后台调用（异步，不卡界面）
$script:GrabBlock = {
    param([string]$base, [string]$platform)
    $port = 8765
    try { $port = [int]((Get-Content -LiteralPath (Join-Path $base 'data\port.txt') -Raw).Trim()) } catch { }
    function _ping {
        try { $null = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/ping" -TimeoutSec 2 -ErrorAction Stop; return $true }
        catch { return $false }
    }
    if (-not (_ping)) {
        $py = $null
        foreach ($rp in @('runtime\python\pythonw.exe', 'runtime\python\python.exe')) {
            $cand = Join-Path $base $rp
            if (Test-Path -LiteralPath $cand) { $py = $cand; break }
        }
        if (-not $py) {
            try {
                $cfgPath = Join-Path $base 'config.json'
                if (Test-Path -LiteralPath $cfgPath) {
                    $cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
                    if ($cfg.python -and (Test-Path -LiteralPath $cfg.python)) { $py = $cfg.python }
                }
            } catch { }
        }
        if (-not $py) {
            foreach ($n in @('pythonw.exe', 'python.exe', 'pythonw', 'python', 'py')) {
                $found = Get-Command $n -ErrorAction SilentlyContinue
                if ($found) { $py = $found.Source; break }
            }
        }
        if ($py) {
            try {
                $srv = Join-Path $base 'server.py'
                Start-Process -FilePath $py -ArgumentList @("`"$srv`"") `
                    -WorkingDirectory $base -WindowStyle Hidden
            } catch { }
        }
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Milliseconds 400
            if (_ping) { break }
        }
        try { $port = [int]((Get-Content -LiteralPath (Join-Path $base 'data\port.txt') -Raw).Trim()) } catch { }
    }
    $body = @{ platform = $platform } | ConvertTo-Json
    try {
        $r = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/harvest/grab" -Method Post `
            -ContentType 'application/json; charset=utf-8' `
            -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 100 -ErrorAction Stop
        $o = @{ ok = $true; link = [string]$r.link; hasInfo = $false
                author = ''; desc = ''; platform = ''; cover = '' }
        $i = $r.info
        if ($i -and $i.ok) {
            $o.hasInfo = $true
            $o.author = [string]$i.author
            $o.desc = [string]$i.desc
            $o.platform = [string]$i.platform
            $o.cover = [string]$i.cover
        }
        return $o
    } catch {
        $msg = $_.Exception.Message
        try {
            $resp = $_.Exception.Response
            if ($resp) {
                $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
                $raw = $sr.ReadToEnd()
                $j = $raw | ConvertFrom-Json
                if ($j.error) { $msg = [string]$j.error }
            }
        } catch { }
        return @{ ok = $false; error = $msg }
    }
}

$script:DownloadBlock = {
    param([string]$base, [string]$link)
    $port = 8765
    try { $port = [int]((Get-Content -LiteralPath (Join-Path $base 'data\port.txt') -Raw).Trim()) } catch { }
    $body = @{ link = $link } | ConvertTo-Json
    try {
        $r = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/harvest/download" -Method Post `
            -ContentType 'application/json; charset=utf-8' `
            -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 600 -ErrorAction Stop
        if (-not $r.ok) { return @{ ok = $false; error = [string]$r.error } }
        return @{ ok = $true; file = [string]$r.file; author = [string]$r.author
                  size = [double]$r.size; itemId = [string]$r.itemId }
    } catch {
        $msg = $_.Exception.Message
        try {
            $resp = $_.Exception.Response
            if ($resp) {
                $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
                $raw = $sr.ReadToEnd()
                $j = $raw | ConvertFrom-Json
                if ($j.error) { $msg = [string]$j.error }
            }
        } catch { }
        return @{ ok = $false; error = $msg }
    }
}

$script:ClipsBlock = {
    param([string]$base)
    $port = 8765
    try { $port = [int]((Get-Content -LiteralPath (Join-Path $base 'data\port.txt') -Raw).Trim()) } catch { }
    try {
        $r = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/harvest/clips" -TimeoutSec 15 -ErrorAction Stop
        $arr = New-Object System.Collections.ArrayList
        foreach ($x in $r.items) {
            $null = $arr.Add(@{ link = [string]$x.link; platform = [string]$x.platform
                                author = [string]$x.author; desc = [string]$x.desc
                                ts = [string]$x.ts; done = [bool]$x.done })
        }
        return @{ ok = $true; items = $arr }
    } catch { return @{ ok = $false; error = $_.Exception.Message; items = (New-Object System.Collections.ArrayList) } }
}

$script:DeleteBlock = {
    param([string]$base, [string]$link)
    $port = 8765
    try { $port = [int]((Get-Content -LiteralPath (Join-Path $base 'data\port.txt') -Raw).Trim()) } catch { }
    $body = @{ link = $link } | ConvertTo-Json
    try {
        $null = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/harvest/clip/delete" -Method Post `
            -ContentType 'application/json; charset=utf-8' `
            -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 15 -ErrorAction Stop
        return @{ ok = $true }
    } catch { return @{ ok = $false; error = $_.Exception.Message } }
}

$script:FolderBlock = {
    param([string]$base)
    $port = 8765
    try { $port = [int]((Get-Content -LiteralPath (Join-Path $base 'data\port.txt') -Raw).Trim()) } catch { }
    try {
        $null = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/open-folder" -Method Post `
            -ContentType 'application/json' -Body '{}' -TimeoutSec 15 -ErrorAction Stop
        return @{ ok = $true }
    } catch { return @{ ok = $false; error = $_.Exception.Message } }
}

$script:WarmBlock = {
    param([string]$base)
    $port = 8765
    try { $port = [int]((Get-Content -LiteralPath (Join-Path $base 'data\port.txt') -Raw).Trim()) } catch { }
    function _ping {
        try { $null = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/ping" -TimeoutSec 2 -ErrorAction Stop; return $true }
        catch { return $false }
    }
    if (_ping) { return @{ ok = $true } }

    # Python 解释器：内置 runtime > config.json > 系统 PATH（pythonw/python/py）
    $py = $null
    foreach ($rp in @('runtime\python\pythonw.exe', 'runtime\python\python.exe')) {
        $cand = Join-Path $base $rp
        if (Test-Path -LiteralPath $cand) { $py = $cand; break }
    }
    if (-not $py) {
        try {
            $cfgPath = Join-Path $base 'config.json'
            if (Test-Path -LiteralPath $cfgPath) {
                $cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
                if ($cfg.python -and (Test-Path -LiteralPath $cfg.python)) { $py = $cfg.python }
            }
        } catch { }
    }
    if (-not $py) {
        foreach ($n in @('pythonw.exe', 'python.exe', 'pythonw', 'python', 'py')) {
            $found = Get-Command $n -ErrorAction SilentlyContinue
            if ($found) { $py = $found.Source; break }
        }
    }
    if (-not $py) { return @{ ok = $false; error = '没找到 Python，请安装 Python 3 或编辑 config.json 指定 python 路径' } }
    try {
        $srv = Join-Path $base 'server.py'
        Start-Process -FilePath $py -ArgumentList @("`"$srv`"") -WorkingDirectory $base -WindowStyle Hidden
    } catch { }
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 400
        if (_ping) { return @{ ok = $true } }
    }
    return @{ ok = $false; error = '后端启动超时，请手动运行 start.bat 看报错' }
}

function Start-Action([string]$name, [scriptblock]$block, [object[]]$arguments) {
    try {
        if ($script:Jobs.ContainsKey($name)) { Log ("job $name skipped (running)"); return }
        $ps = [PowerShell]::Create()
        $null = $ps.AddScript($block)
        foreach ($a in $arguments) { $null = $ps.AddArgument($a) }
        $h = $ps.BeginInvoke()
        $script:Jobs[$name] = [pscustomobject]@{ PS = $ps; Handle = $h }
        Log ("job $name started, args=" + ($arguments -join ' | '))
    } catch { Log ("job start FAIL ($name): " + $_.Exception.Message) }
}

function Complete-Action([string]$name, $result) {
    if ($name -eq 'grab') {
        $script:Busy = $false
        $script:ctTimer.Stop()
        Set-ClickThrough $false     # 抓完立刻恢复可点击（球一直在原位，不会消失）
        try { $script:ClipSeq = [WB.Clip]::GetClipboardSequenceNumber() } catch { }
        if ($result -and $result.ok) {
            Set-Visual 'done' '已抓到'
            if ($result.hasInfo) {
                Render-PanelCard @{ link = [string]$result.link; author = [string]$result.author
                                    desc = [string]$result.desc; platform = [string]$result.platform
                                    cover = [string]$result.cover }
                Set-PanelStatus ('已抓到：' + $result.author + ' · 点「下载到素材库」') '#6EE7B7'
                Show-Toast ('已抓到：' + $result.author) '#6EE7B7'
            } else {
                Render-PanelCard $null
                Set-PanelStatus '抓到链接，但没解析出标题（可能是私密或已删除）' '#FFB45C'
                Show-Toast '抓到链接但解析失败' '#FFB45C'
            }
            Show-Panel
            Refresh-Clips
        } else {
            $msg = '抓取失败'
            if ($result -and $result.error) { $msg = [string]$result.error }
            Set-Visual 'error' '抓取失败'
            Set-PanelStatus $msg '#FF7B7B'
            Show-Panel
            Show-Toast $msg '#FF7B7B'
        }
        $script:resetTimer.Stop(); $script:resetTimer.Start()
    } elseif ($name -eq 'dl') {
        $script:DlBusy = $false
        if ($result -and $result.ok) {
            $mb = [math]::Round(([double]$result.size) / 1048576, 1)
            Set-Visual 'done' '已入库'
            Show-Panel
            Set-PanelStatus ('已入库：' + $result.author + ' ' + $mb + 'MB · 点素材文件夹查看') '#6EE7B7'
            Show-Toast ('已入库 ' + $mb + 'MB') '#6EE7B7'
            if ($script:CurLink -and $result.itemId) { $script:DoneMap[$script:CurLink] = [string]$result.itemId }
            if ($script:CurInfo) { Render-PanelCard $script:CurInfo }
            Refresh-Clips
        } else {
            $msg = '下载失败'
            if ($result -and $result.error) { $msg = [string]$result.error }
            Set-Visual 'error' '下载失败'
            Show-Panel
            Set-PanelStatus $msg '#FF7B7B'
            Show-Toast $msg '#FF7B7B'
        }
        $script:resetTimer.Stop(); $script:resetTimer.Start()
    } elseif ($name -eq 'autoclip') {
        # 剪贴板里出现新链接 → 后台解析并入库，安静地提示一下，不打断当前操作
        try { $script:ClipSeq = [WB.Clip]::GetClipboardSequenceNumber() } catch { }
        if ($result -and $result.ok -and $result.author) {
            Set-Visual 'done' '已解析'
            Show-Toast ('已解析：' + $result.author + '（点球可下载）') '#6EE7B7'
            if ($script:CurInfo -eq $null -or -not $script:CurInfo) {
                Render-PanelCard @{ link = [string]$result.link; author = [string]$result.author
                                    desc = [string]$result.desc; platform = [string]$result.platform
                                    cover = [string]$result.cover }
            }
            Refresh-Clips
            $script:resetTimer.Stop(); $script:resetTimer.Start()
        } elseif ($result -and -not $result.ok) {
            Log ('autoclip: ' + [string]$result.error)
        }
    } elseif ($name -eq 'clips') {
        if ($result -and $result.ok) {
            $script:Clips = @($result.items)
            Render-PanelList
            if ($script:CurInfo) { $script:CurLink = [string]$script:CurInfo.link; Render-CardBtns $script:CurLink }
        }
    } elseif ($name -eq 'del') {
        Refresh-Clips
    } elseif ($name -eq 'folder') {
        if ($result -and -not $result.ok) { Set-PanelStatus '打不开素材文件夹' '#FF7B7B' }
    }
}

$script:pump = New-Object System.Windows.Threading.DispatcherTimer
$script:pump.Interval = [TimeSpan]::FromMilliseconds(220)
$script:pump.Add_Tick({
    foreach ($k in @($script:Jobs.Keys)) {
        $j = $script:Jobs[$k]
        if (-not $j.Handle.IsCompleted) { continue }
        $script:Jobs.Remove($k)
        $out = $null
        try { $out = $j.PS.EndInvoke($j.Handle) } catch { Log ("job $k FAIL: " + $_.Exception.Message) }
        try { $j.PS.Dispose() } catch { }
        $val = $null
        if ($out -and $out.Count -gt 0) { $val = $out[$out.Count - 1] }
        Complete-Action $k $val
    }
})

$script:resetTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:resetTimer.Interval = [TimeSpan]::FromSeconds(4)
$script:resetTimer.Add_Tick({
    $script:resetTimer.Stop()
    if ($script:Busy -or $script:DlBusy) { return }
    Set-Visual 'idle' '待命'
})

# ================================================================ 动作
function Invoke-Grab([string]$mode) {
    if ($script:Busy) { Show-Toast '正在抓取，稍等一下' '#FFB45C'; return }
    $script:Busy = $true
    $label = @{ auto = '抓取中'; wx = '抓微信'; dy = '抓抖音'; clip = '读剪贴板' }[$mode]
    if (-not $label) { $label = '抓取中' }
    Set-Visual 'busy' $label
    Show-Toast $label '#FFB45C'
    if ($script:PanelBox) {
        $hint = @{ auto = '正在读当前窗口（微信/抖音）…'; wx = '正在微信视频号里点分享复制…'
                   dy = '正在读抖音地址栏…'; clip = '正在读剪贴板里的链接…' }[$mode]
        Set-PanelStatus $hint '#FFB45C'
        # 要让位点对方的「分享」按钮：面板收起，球留在原地并临时变成鼠标穿透
        # （以前是把整个窗口挪到屏幕外，看起来球会消失一下）
        if ($mode -ne 'clip') {
            Hide-Panel
            Set-ClickThrough $true
            $script:ctTimer.Stop(); $script:ctTimer.Start()
        } else {
            Show-Panel
        }
    } elseif ($mode -ne 'clip') {
        Set-ClickThrough $true
        $script:ctTimer.Stop(); $script:ctTimer.Start()
    }
    Start-Action 'grab' $script:GrabBlock @($script:Base, $mode)
    # 任务没起来（极少见）就别把球锁死
    if (-not $script:Jobs.ContainsKey('grab')) {
        $script:Busy = $false
        $script:ctTimer.Stop()
        Set-ClickThrough $false
    }
}

function Invoke-PanelDownload([string]$link) {
    Log ("panel download link=[" + $link + "]")
    if (-not $link) { Set-PanelStatus '没有链接' '#FF7B7B'; return }
    if ($script:DlBusy) { Set-PanelStatus '上一条还在下载，稍等一下' '#FFB45C'; return }
    $who = ''
    $hit = Find-Clip $link
    if ($hit -and $hit.author) { $who = [string]$hit.author }
    elseif ($script:CurInfo -and [string]$script:CurInfo.link -eq $link) { $who = [string]$script:CurInfo.author }
    $script:DlBusy = $true
    Set-Visual 'busy' '下载中'
    Set-PanelStatus ('正在下载' + $(if ($who) { '：' + $who } else { '' }) + '…（长视频要等一会儿）') '#FFB45C'
    Log 'panel download -> Start-Action dl'
    Start-Action 'dl' $script:DownloadBlock @($script:Base, $link)
}

function Invoke-PanelDelete([string]$link) {
    if (-not $link) { return }
    Start-Action 'del' $script:DeleteBlock @($script:Base, $link)
    Set-PanelStatus '已从历史里删掉这条' '#7A9AA6'
}

function Open-Folder {
    Start-Action 'folder' $script:FolderBlock @($script:Base)
}

function Quit-App {
    $script:Quitting = $true
    try { $win.Close() } catch { }
    try { if ($script:App) { $script:App.Shutdown() } } catch { }
}

# ---------- 拖动 / 点击 ----------
$script:downScreen = $null
$script:startLeft = 0.0
$script:startTop = 0.0
$script:moved = $false

$Ball.Add_MouseLeftButtonDown({
    param($s, $e)
    if ($e.ChangedButton -ne [System.Windows.Input.MouseButton]::Left) { return }
    # 连体窗口：拖球 = 整块窗口跟着走（系统级拖动，鼠标跑多快都不丢）
    $script:startLeft = [double]$win.Left
    $script:startTop = [double]$win.Top
    $script:moved = $false
    try { $win.DragMove() } catch { }
    $dx = [Math]::Abs([double]$win.Left - $script:startLeft)
    $dy = [Math]::Abs([double]$win.Top - $script:startTop)
    if (($dx + $dy) -ge 3) {
        $script:moved = $true
        Clamp-Pos
        Save-State
    } else {
        $script:moved = $false
        Invoke-Grab 'auto'
    }
    $e.Handled = $true
})

$Ball.Add_MouseEnter({
    $ax = New-Object System.Windows.Media.Animation.DoubleAnimation($script:HoverScale.ScaleX, 1.08, [TimeSpan]::FromMilliseconds(140))
    $ay = New-Object System.Windows.Media.Animation.DoubleAnimation($script:HoverScale.ScaleY, 1.08, [TimeSpan]::FromMilliseconds(140))
    $script:HoverScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $ax)
    $script:HoverScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $ay)
})
$Ball.Add_MouseLeave({
    $ax = New-Object System.Windows.Media.Animation.DoubleAnimation($script:HoverScale.ScaleX, 1.0, [TimeSpan]::FromMilliseconds(180))
    $ay = New-Object System.Windows.Media.Animation.DoubleAnimation($script:HoverScale.ScaleY, 1.0, [TimeSpan]::FromMilliseconds(180))
    $script:HoverScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $ax)
    $script:HoverScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $ay)
})

$MenuGrab.Add_Click({ $null = Invoke-Grab 'auto' })
$MenuGrabWx.Add_Click({ $null = Invoke-Grab 'wx' })
$MenuGrabDy.Add_Click({ $null = Invoke-Grab 'dy' })
$MenuClip.Add_Click({ $null = Invoke-Grab 'clip' })
$MenuAutoClip.IsChecked = [bool]$script:AutoClip
$MenuAutoClip.Add_Click({
    $script:AutoClip = [bool]$MenuAutoClip.IsChecked
    Save-State
    if ($script:AutoClip) { Show-Toast '已开启：复制链接自动解析' '#6EE7B7' }
    else { Show-Toast '已关闭自动解析剪贴板' '#FFB45C' }
})
$MenuPanel.Add_Click({ if ($script:PanelOpen) { Hide-Panel } else { Show-Panel; Refresh-Clips } })
$MenuOpen.Add_Click({ Open-Folder })
$MenuHide.Add_Click({ try { Hide-Panel; $win.Hide() } catch { } })
$MenuQuit.Add_Click({ Quit-App })

# ---------- 剪贴板监听：手动复制链接（抖音/视频号/分享文案）也自动解析入库 ----------
function Enable-ClipWatch {
    try {
        if (-not ('WB.Clip' -as [type])) {
            Add-Type -Namespace WB -Name Clip -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern uint GetClipboardSequenceNumber();
'@ -ErrorAction Stop
        }
        $script:ClipSeq = [WB.Clip]::GetClipboardSequenceNumber()
        $script:clipTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:clipTimer.Interval = [TimeSpan]::FromMilliseconds(1200)
        $script:clipTimer.Add_Tick({
            try {
                if (-not $script:AutoClip) { return }
                if ($script:Busy -or $script:DlBusy) { return }
                if ($script:Jobs.ContainsKey('grab') -or $script:Jobs.ContainsKey('autoclip')) { return }
                $seq = [WB.Clip]::GetClipboardSequenceNumber()
                if ($seq -eq $script:ClipSeq) { return }
                # 读剪贴板要能失败重试：抖音/微信复制时剪贴板会被占住，
                # 读失败绝不能把 seq 记为已处理，否则这条链接就永远丢了
                $txt = ''
                for ($k = 0; $k -lt 4; $k++) {
                    try { $txt = [System.Windows.Clipboard]::GetText() } catch { $txt = '' }
                    if ($txt) { break }
                    Start-Sleep -Milliseconds 110
                }
                if (-not $txt) {
                    Log 'clipwatch: 剪贴板读取失败，下轮重试'
                    return
                }
                $script:ClipSeq = $seq
                if ($txt -notmatch '(?i)https?://(v\.douyin\.com|(www\.)?douyin\.com/(video|jingxuan)|weixin\.qq\.com/sph/|channels\.weixin\.qq\.com)') { return }
                if ($txt -eq $script:LastClipText) { return }
                $script:LastClipText = $txt
                Log 'clipwatch: 剪贴板出现新链接，自动解析'
                Start-Action 'autoclip' $script:GrabBlock @($script:Base, 'clip')
            } catch { Log ('clipwatch FAIL: ' + $_.Exception.Message) }
        })
        $script:clipTimer.Start()
        Log ('clipwatch started, autoclip=' + $script:AutoClip)
    } catch { Log ('clipwatch init FAIL: ' + $_.Exception.Message) }
}

# ---------- 全局热键 ----------
$script:HotSrc = $null
$script:HotHook = $null
function Enable-Hotkeys {
    try {
        if (-not ('WB.Hot' -as [type])) {
            Add-Type -Namespace WB -Name Hot -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool RegisterHotKey(System.IntPtr h, int id, uint mod, uint vk);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool UnregisterHotKey(System.IntPtr h, int id);
'@ -ErrorAction Stop
        }
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($win)
        $script:HotSrc = [System.Windows.Interop.HwndSource]::FromHwnd($helper.Handle)
        $script:HotHook = [System.Windows.Interop.HwndSourceHook]{
            param($hWnd, $msg, $wParam, $lParam, $handled)
            if ($msg -eq 0x0312) {
                try {
                    $id = $wParam.ToInt32()
                    if ($id -eq 45101) { $null = Invoke-Grab 'auto' }
                    elseif ($id -eq 45102) { $null = Invoke-Grab 'dy' }
                    elseif ($id -eq 45103) { $null = Invoke-Grab 'clip' }
                    elseif ($id -eq 45104) { Open-Folder }
                    elseif ($id -eq 45105) { Show-Panel; Refresh-Clips }
                } catch { Log ('hotkey handler FAIL: ' + $_.Exception.Message) }
            }
            return [IntPtr]::Zero
        }
        $script:HotSrc.AddHook($script:HotHook)
        $h1 = [WB.Hot]::RegisterHotKey($script:HotSrc.Handle, 45101, 3, 0x47)   # Ctrl+Alt+G
        $h2 = [WB.Hot]::RegisterHotKey($script:HotSrc.Handle, 45102, 3, 0x59)   # Ctrl+Alt+Y
        $h3 = [WB.Hot]::RegisterHotKey($script:HotSrc.Handle, 45103, 3, 0x44)   # Ctrl+Alt+D
        $h4 = [WB.Hot]::RegisterHotKey($script:HotSrc.Handle, 45104, 3, 0x50)   # Ctrl+Alt+P
        $h5 = [WB.Hot]::RegisterHotKey($script:HotSrc.Handle, 45105, 3, 0x4D)   # Ctrl+Alt+M
        Log "hotkeys: G=$h1 Y=$h2 D=$h3 P=$h4 M=$h5"
    } catch { Log ('hotkey FAIL: ' + $_.Exception.Message) }
}

# ---------- 托盘 ----------
$notify = New-Object System.Windows.Forms.NotifyIcon
try {
    if (Test-Path -LiteralPath $script:IconPath) {
        $notify.Icon = New-Object System.Drawing.Icon($script:IconPath)
    } else {
        $notify.Icon = [System.Drawing.SystemIcons]::Application
    }
    $notify.Text = '素材收割球'
    $notify.Visible = $true
    $notify.Add_MouseClick({
        param($s, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            $win.Show()
            $win.Topmost = $false; $win.Topmost = $true
            Show-Panel
            Refresh-Clips
        }
    })
} catch { Log ('tray FAIL: ' + $_.Exception.Message) }

$win.Add_Loaded({
    Set-Visual 'idle' '待命'
    Build-Panel
    Show-Toast '点球抓视频 · 复制链接也能自动解析' '#7DE3F2'
    Enable-Hotkeys
    Enable-ClipWatch
    $script:pump.Start()
    Start-Action 'warm' $script:WarmBlock @($script:Base)
})

$win.Add_Closed({
    try { $script:pump.Stop() } catch { }
    try { $notify.Visible = $false; $notify.Dispose() } catch { }
})

Log ('show at ' + $win.Left + ',' + $win.Top)
# 不能用 ShowDialog()：窗口一旦 Hide()（隐藏球 / 让位）模态循环就结束、进程直接退出。
# 用 Application.Run + OnExplicitShutdown，只有「退出悬浮球」才真正结束。
$script:App = New-Object System.Windows.Application
$script:App.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
try {
    $script:App.Run($win) | Out-Null
} catch { Log ('app run FAIL: ' + $_.Exception.Message) }
Log '=== ball exit ==='
