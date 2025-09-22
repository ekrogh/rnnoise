import argparse
import torch
from pathlib import Path
from model import GuitarSepNet


def parse_args():
    p = argparse.ArgumentParser("Export GuitarSepNet to ONNX")
    p.add_argument('--checkpoint', type=str, default='', help='Optional .pt checkpoint (state_dict)')
    p.add_argument('--out', type=str, default='guitar_mask.onnx', help='Output ONNX file')
    p.add_argument('--n-freq', type=int, default=257)
    p.add_argument('--model-dim', type=int, default=192)
    p.add_argument('--n-blocks', type=int, default=8)
    p.add_argument('--opset', type=int, default=17)
    return p.parse_args()


def main():
    args = parse_args()
    net = GuitarSepNet(n_freq=args.n_freq, model_dim=args.model_dim, n_blocks=args.n_blocks)
    if args.checkpoint and Path(args.checkpoint).is_file():
        ckpt = torch.load(args.checkpoint, map_location='cpu')
        sd = ckpt.get('state_dict', ckpt)
        missing, unexpected = net.load_state_dict(sd, strict=False)
        print(f"Loaded checkpoint; missing={missing}, unexpected={unexpected}")
    net.eval()

    # Dummy input (batch=1, F, T=200 frames)
    dummy = torch.randn(1, args.n_freq, 200)
    torch.onnx.export(
        net,
        dummy,
        args.out,
        input_names=['features'],
        output_names=['mask'],
        dynamic_axes={'features': {0: 'batch', 2: 'frames'}, 'mask': {0: 'batch', 2: 'frames'}},
        opset_version=args.opset,
        do_constant_folding=True,
    )
    print(f"Exported ONNX: {args.out}")


if __name__ == '__main__':
    main()
