# Локальный сервер для стрима «Турича».
#  1) принимает данные из Доты (Game State Integration) на http://localhost:8766/gsi
#  2) отдаёт последнее состояние игры на http://localhost:8766/gsi/state
#  3) раздаёт сайт, чтобы HUD в OBS открывался как http://localhost:8766/hud/?room=КОД
# Запуск: двойной клик по start-hud.bat. Окно не закрывать, пока идёт стрим.

$port = 8766
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$saveDir = Join-Path $PSScriptRoot "matches"
New-Item -ItemType Directory -Force $saveDir | Out-Null

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")
try { $listener.Start() } catch { Write-Host "Не удалось занять порт $port. Возможно, сервер уже запущен в другом окне." -ForegroundColor Red; Read-Host "Enter — закрыть"; exit 1 }

Write-Host ""
Write-Host "  Турич — сервер HUD запущен" -ForegroundColor Yellow
Write-Host "  HUD для OBS:  http://localhost:$port/hud/?room=КОД_КОМНАТЫ  (код покажет пульт)"
Write-Host "  Пульт:        http://localhost:$port/hud/?panel=1"
Write-Host "  Ждём данные из Доты на /gsi ... (Ctrl+C — остановить)"
Write-Host ""

$types = @{ ".html"="text/html; charset=utf-8"; ".css"="text/css"; ".js"="application/javascript"; ".webp"="image/webp"; ".png"="image/png"; ".svg"="image/svg+xml"; ".json"="application/json; charset=utf-8" }
$utf8 = New-Object System.Text.UTF8Encoding $false
$state = "{}"; $stateTime = [DateTime]::MinValue; $lastMatch = ""; $lastSaved = ""

function Send($ctx, [int]$code, [string]$type, [byte[]]$bytes) {
  $r = $ctx.Response
  $r.StatusCode = $code
  $r.Headers.Add("Access-Control-Allow-Origin", "*")
  $r.Headers.Add("Access-Control-Allow-Private-Network", "true")
  $r.Headers.Add("Cache-Control", "no-store")
  if ($type) { $r.ContentType = $type }
  if ($bytes) { $r.OutputStream.Write($bytes, 0, $bytes.Length) }
  $r.Close()
}

while ($listener.IsListening) {
  try {
    $ctx = $listener.GetContext()
    $req = $ctx.Request
    $path = [Uri]::UnescapeDataString($req.Url.AbsolutePath)

    if ($req.HttpMethod -eq "OPTIONS") { Send $ctx 204 $null $null; continue }

    # данные из Доты
    if ($path -eq "/gsi" -and $req.HttpMethod -eq "POST") {
      $body = (New-Object System.IO.StreamReader($req.InputStream, $utf8)).ReadToEnd()
      # запоминаем только снимки с данными игроков (в меню и после выхода из лобби их нет)
      if ($body -match '"team2"' -and $body -match '"matchid"\s*:\s*"(\d+)"') {
        $mid = $Matches[1]
        $state = $body; $stateTime = Get-Date
        if ($mid -ne $lastMatch) { $lastMatch = $mid; Write-Host ("[{0:HH:mm:ss}] Данные игры получены, матч {1}" -f (Get-Date), $mid) -ForegroundColor Green }
        # итог игры сохраняем в файл (stream/matches/<матч>.json)
        if ($body -match '"win_team"\s*:\s*"(radiant|dire)"' -and $lastSaved -ne $mid) {
          $lastSaved = $mid
          [IO.File]::WriteAllText((Join-Path $saveDir "$mid.json"), $body, $utf8)
          Write-Host ("[{0:HH:mm:ss}] Игра окончена, победа {1}. Итог сохранён: stream\matches\{2}.json" -f (Get-Date), $Matches[1], $mid) -ForegroundColor Yellow
        }
      }
      Send $ctx 200 "text/plain" $null; continue
    }

    # последнее состояние для HUD
    if ($path -eq "/gsi/state") {
      $age = if ($stateTime -eq [DateTime]::MinValue) { -1 } else { [int]((Get-Date) - $stateTime).TotalSeconds }
      $json = '{"age":' + $age + ',"data":' + $state + '}'
      Send $ctx 200 "application/json; charset=utf-8" $utf8.GetBytes($json); continue
    }

    # сохранённые матчи: /gsi/match/<id>
    if ($path -match '^/gsi/match/(\d+)$') {
      $f = Join-Path $saveDir ($Matches[1] + ".json")
      if (Test-Path $f) { Send $ctx 200 "application/json; charset=utf-8" ([IO.File]::ReadAllBytes($f)) } else { Send $ctx 404 "text/plain" $null }
      continue
    }

    # файлы сайта
    $rel = $path.TrimStart('/'); if ($rel -eq "" -or $rel.EndsWith("/")) { $rel += "index.html" }
    $file = Join-Path $root $rel
    if (Test-Path $file -PathType Container) { $file = Join-Path $file "index.html" }
    $full = [IO.Path]::GetFullPath($file)
    if ((Test-Path $full -PathType Leaf) -and $full.StartsWith($root)) {
      $ext = [IO.Path]::GetExtension($full).ToLower()
      $t = if ($types[$ext]) { $types[$ext] } else { "application/octet-stream" }
      Send $ctx 200 $t ([IO.File]::ReadAllBytes($full))
    } else { Send $ctx 404 "text/plain" $null }
  } catch {
    Write-Host ("Ошибка: " + $_.Exception.Message) -ForegroundColor DarkGray
    try { $ctx.Response.Close() } catch {}
  }
}
