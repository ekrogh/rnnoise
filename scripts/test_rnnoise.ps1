# 1. Baseline problematic file with bypass (to confirm audio \\buffalo\Media\Music\iTunes\iTunes Media\Music\Eric Clapton_B.B. King\Riding with the King works)
# $env:RN_GUITAR_BYPASS='1'
# pwsh .\scripts\rnnoise_wav.ps1 -InWav "\\buffalo\Media\Music\iTunes\iTunes Media\Music\Eric Clapton_B.B. King\Riding with the King\\01 Riding With The King.mp3" -OutWav .\processed\\king_bypass.wav

# 2. Mid-band activation + auto floor (should retain more guitar)
# Remove-Item Env:RN_GUITAR_BYPASS -ErrorAction SilentlyContinue
# $env:RN_GUITAR_ACT_SOURCE='mid'
# $env:RN_GUITAR_AUTO_FLOOR='1'
# $env:RN_GUITAR_DEBUG='1'
# pwsh .\scripts\rnnoise_wav.ps1 -InWav "\\buffalo\Media\Music\iTunes\iTunes Media\Music\Eric Clapton_B.B. King\Riding with the King\\01 Riding With The King.mp3" -OutWav .\processed\\king_mid.wav -GateMinScale 0.15

# 3. Blended activation with slightly softer threshold
# $env:RN_GUITAR_ACT_SOURCE='blend'
# pwsh .\scripts\rnnoise_wav.ps1 -InWav "\\buffalo\Media\Music\iTunes\iTunes Media\Music\Eric Clapton_B.B. King\Riding with the King\\01 Riding With The King.mp3" -OutWav .\processed\\king_blend.wav -GateThresh 0.35 -GateMinScale 0.20

# 4. Aggressive (for comparison)
$env:RN_GUITAR_ACT_SOURCE='vad'
pwsh .\scripts\rnnoise_wav.ps1 -InWav "\\buffalo\Media\Music\iTunes\iTunes Media\Music\Eric Clapton_B.B. King\Riding with the King\\01 Riding With The King.mp3" -OutWav .\processed\\king_vad_aggressive.wav -GateThresh 0.50 -GateMinScale 0.10

 & "C:\Program Files\VideoLAN\VLC\vlc.exe" .\processed\king_bypass.wav
