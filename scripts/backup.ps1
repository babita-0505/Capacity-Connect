# Capacity Connect - Automated Backup Script for Windows (PowerShell)
param(
    [string]$BackupDir = ".\backups"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -Path $BackupDir)) {
    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
}

$Timestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
$OutputFile = Join-Path -Path $BackupDir -ChildPath "backup_$Timestamp.sql"

Write-Host "Creating database backup from Docker..." -ForegroundColor Cyan

docker compose exec -T db pg_dump -U postgres capacity_connect | Out-File -FilePath $OutputFile -Encoding utf8

if (Test-Path $OutputFile) {
    $Size = (Get-Item $OutputFile).Length / 1MB
    Write-Host ("Backup completed successfully: {0} ({1:N2} MB)" -f $OutputFile, $Size) -ForegroundColor Green
} else {
    Write-Host "Backup failed to generate." -ForegroundColor Red
}
