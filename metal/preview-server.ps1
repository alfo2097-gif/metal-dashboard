param([int]$Port = 8088)
$root = [IO.Path]::GetFullPath($PSScriptRoot)
$listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
$listener.Start()
Write-Host "Metal preview http://127.0.0.1:$Port"
try {
  while ($true) {
    $client = $listener.AcceptTcpClient()
    try {
      $stream = $client.GetStream()
      $stream.ReadTimeout = 5000
      $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::ASCII, $false, 1024, $true)
      $first = $reader.ReadLine()
      while ($reader.ReadLine()) { }
      $request = ($first -split ' ')[1]
      $relative = [Uri]::UnescapeDataString(($request -split '\?')[0]).TrimStart('/')
      if (-not $relative) { $relative = 'metal_dashboard.html' }
      $path = [IO.Path]::GetFullPath((Join-Path $root $relative))
      $ext = [IO.Path]::GetExtension($path)
      $mime = @{ '.html'='text/html; charset=utf-8'; '.js'='text/javascript; charset=utf-8'; '.css'='text/css; charset=utf-8'; '.json'='application/json; charset=utf-8' }
      if ($first -notmatch '^GET ' -or -not $path.StartsWith($root + [IO.Path]::DirectorySeparatorChar) -or -not $mime.ContainsKey($ext) -or -not [IO.File]::Exists($path)) {
        $status = '404 Not Found'; $bytes = [Text.Encoding]::UTF8.GetBytes('Not found'); $type = 'text/plain'
      } else {
        $status = '200 OK'; $bytes = [IO.File]::ReadAllBytes($path); $type = $mime[$ext]
      }
      $header = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status`r`nContent-Type: $type`r`nContent-Length: $($bytes.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n")
      $stream.Write($header, 0, $header.Length)
      $stream.Write($bytes, 0, $bytes.Length)
    } catch { Write-Host $_.Exception.Message }
    finally { $client.Close() }
  }
} finally { $listener.Stop() }
