# Install pinned torch CUDA 11.8 build (PowerShell syntax)
# & pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cu118 torch==2.7.1
# Quick validation (avoid bash heredoc which caused parser error). For multi-line logic you can also use a here-string and pipe to python -.
# python -c "import torch;print('Torch:',torch.__version__,'Build CUDA:',torch.version.cuda,'Avail:',torch.cuda.is_available());print(('Device: '+torch.cuda.get_device_name(0)) if torch.cuda.is_available() else 'CUDA not available post-install.')"

# $env:CUDA_WHEEL_CHANNEL='cu118'     # Or set nothing to try GPU then fallback
# $env:USE_GPU=1   
Remove-Item Env:USE_GPU        -ErrorAction SilentlyContinue
Remove-Item Env:REQUIRE_GPU    -ErrorAction SilentlyContinue
$env:VENV_PATH='D:\venvs\rnnoise_train'
$env:FORCE_CPU = 1
$env:CUDA_WHEEL_CHANNEL = 'cpu'
$env:TORCH_VERSION='2.7.1'          # Stable
$env:FULL_TRAIN=1
$env:FORCE_TRAIN=1
$env:EPOCHS=50
$env:VerboseDeps=1

pwsh ./scripts/one_shot_train_onnx.ps1

Remove-Item env:FORCE_CPU  -ErrorAction SilentlyContinue
Remove-Item Env:REQUIRE_GPU    -ErrorAction SilentlyContinue
Remove-Item Env:USE_GPU -ErrorAction SilentlyContinue
Remove-Item Env:VENV_PATH -ErrorAction SilentlyContinue
Remove-Item Env:TORCH_VERSION -ErrorAction SilentlyContinue
Remove-Item Env:CUDA_WHEEL_CHANNEL -ErrorAction SilentlyContinue
Remove-Item Env:FULL_TRAIN -ErrorAction SilentlyContinue
Remove-Item Env:FORCE_TRAIN -ErrorAction SilentlyContinue
Remove-Item Env:EPOCHS -ErrorAction SilentlyContinue
Remove-Item Env:VerboseDeps -ErrorAction SilentlyContinue


# pwsh -ExecutionPolicy Bypass -File scripts\train_export_parity_deploy.ps1 `
#   -FeaturesFile features.f32 `
#   -OutputDir checkpoints\gtr_gpu_test `
#   -Epochs 1 `
#   -PreferGPU `
#   -CudaChannel cu126 `
#   -AutoInstallDeps `
#   -VenvPath D:\venvs\rnnoise_train `
#   -TrainDir rnnoise_train `
#   -WriteRequirements `
#   -VerboseDeps
