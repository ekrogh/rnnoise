$env:VENV_PATH='D:\venvs\rnnoise_train'
# $env:VENV_PATH='D:\venvs\rnnoise_train'
$env:TORCH_VERSION='2.3.1'          # Stable
$env:CUDA_WHEEL_CHANNEL='cu121'     # Or set nothing to try GPU then fallback
$env:USE_GPU=1   
$env:FULL_TRAIN=1
$env:FORCE_TRAIN=1
$env:EPOCHS=50
pwsh ./scripts/one_shot_train_onnx.ps1
