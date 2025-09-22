import argparse
import torch
from pathlib import Path
import rnnoise


def parse_args():
    p = argparse.ArgumentParser("Export RNNoise (recurrent) to ONNX")
    p.add_argument('--checkpoint', type=str, required=True, help='Path to training checkpoint (.pth) containing state_dict')
    p.add_argument('--out', type=str, default='rnnoise.onnx', help='Output ONNX filename')
    p.add_argument('--opset', type=int, default=17)
    p.add_argument('--dummy-seq', type=int, default=200, help='Dummy sequence length for export (only shapes)')
    p.add_argument('--no-dynamic', action='store_true', help='Disable dynamic axes for batch/frames')
    p.add_argument('--cond-size', type=int, default=128, help='Conditioning size must match training if not embedded in checkpoint')
    p.add_argument('--gru-size', type=int, default=384, help='GRU size must match training if not embedded in checkpoint')
    return p.parse_args()


def build_model(ckpt_path, cond_size, gru_size):
    ckpt = torch.load(ckpt_path, map_location='cpu')
    model_kwargs = ckpt.get('model_kwargs', {'cond_size': cond_size, 'gru_size': gru_size})
    model = rnnoise.RNNoise(**model_kwargs)
    sd = ckpt.get('state_dict', ckpt)
    missing, unexpected = model.load_state_dict(sd, strict=False)
    print(f"Loaded checkpoint; missing={missing}, unexpected={unexpected}")
    model.eval()
    return model


def main():
    args = parse_args()
    model = build_model(args.checkpoint, args.cond_size, args.gru_size)

    class _ExportWrapper(torch.nn.Module):
        def __init__(self, core):
            super().__init__()
            self.core = core
        def forward(self, features, state1, state2, state3):
            gain, vad, states = self.core(features, states=[state1, state2, state3])
            return gain, vad, states[0], states[1], states[2]

    wrapper = _ExportWrapper(model)
    bsz = 1
    T = max(1, int(args.dummy_seq))
    dummy_feats = torch.randn(bsz, T, 65)
    dummy_state = torch.zeros(1, bsz, model.gru_size)
    inputs = (dummy_feats, dummy_state, dummy_state, dummy_state)

    input_names = ['features', 'state1', 'state2', 'state3']
    output_names = ['gain', 'vad', 'out_state1', 'out_state2', 'out_state3']
    dynamic_axes = None
    if not args.no_dynamic:
        dynamic_axes = {
            'features': {0: 'batch', 1: 'frames'},
            'gain': {0: 'batch', 1: 'frames'},
            'vad': {0: 'batch', 1: 'frames'},
            'state1': {1: 'batch'},
            'state2': {1: 'batch'},
            'state3': {1: 'batch'},
            'out_state1': {1: 'batch'},
            'out_state2': {1: 'batch'},
            'out_state3': {1: 'batch'}
        }

    torch.onnx.export(
        wrapper,
        inputs,
        args.out,
        input_names=input_names,
        output_names=output_names,
        dynamic_axes=dynamic_axes,
        opset_version=args.opset,
        do_constant_folding=True,
    )
    print(f"Exported RNNoise ONNX model to {args.out} (opset={args.opset}, dynamic={dynamic_axes is not None})")


if __name__ == '__main__':
    main()
