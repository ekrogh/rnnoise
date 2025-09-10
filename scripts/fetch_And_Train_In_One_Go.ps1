# Fetch and train in one go
# pwsh
pipeline_guitar.ps1 -DataMode Real -GuitarDir .\data\guitar_clean -InterfereDir .\data\interfere -FetchFromUrls -FeatureCount 5000 -Epochs 100