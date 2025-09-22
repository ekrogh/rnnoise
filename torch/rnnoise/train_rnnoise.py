"""
/* Copyright (c) 2024 Jean-Marc Valin */
/*
   Redistribution and use in source and binary forms, with or without
   modification, are permitted provided that the following conditions
   are met:

   - Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.

   - Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
   ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
   LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
   A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER
   OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
   EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
   PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
   PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
   LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
   NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
   SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/
"""

import numpy as np
import torch
from torch import nn
import torch.nn.functional as F
import tqdm
import os
import rnnoise
import argparse

parser = argparse.ArgumentParser()

parser.add_argument('features', type=str, help='path to feature file in .f32 format')
parser.add_argument('output', type=str, help='path to output folder')

parser.add_argument('--suffix', type=str, help="model name suffix", default="")
parser.add_argument('--cuda-visible-devices', type=str, help="comma separates list of cuda visible device indices, default: CUDA_VISIBLE_DEVICES", default=None)
parser.add_argument('--workers', type=int, help='DataLoader worker processes (Windows default override to 0 if >0)', default=4)
parser.add_argument('--use-guitar-activity-label', action='store_true', help='If feature file includes extra guitar activity channel (dim=99), use it instead of legacy vad channel')
parser.add_argument('--export-onnx', type=str, default=None, help='Optional path to export ONNX model after final epoch (e.g. rnnoise.onnx)')
parser.add_argument('--onnx-opset', type=int, default=17, help='ONNX opset version to use when exporting')
parser.add_argument('--onnx-no-dynamic', action='store_true', help='Disable dynamic axes (export fixed shapes)')
parser.add_argument('--onnx-dummy-seq', type=int, default=200, help='Dummy sequence length for ONNX export (only affects exported initial shape)')
parser.add_argument('--force-cpu', action='store_true', help='Force CPU training even if CUDA is available')
parser.add_argument('--warmup-batch-size', type=int, default=0, help='Optional one-time smaller batch size for first iteration (0=disabled)')
parser.add_argument('--warmup-seq-len', type=int, default=0, help='Optional one-time shorter sequence length for first iteration (0=disabled)')


model_group = parser.add_argument_group(title="model parameters")
model_group.add_argument('--cond-size', type=int, help="first conditioning size, default: 128", default=128)
model_group.add_argument('--gru-size', type=int, help="first conditioning size, default: 384", default=384)

training_group = parser.add_argument_group(title="training parameters")
training_group.add_argument('--batch-size', type=int, help="batch size, default: 128", default=128)
training_group.add_argument('--lr', type=float, help='learning rate, default: 1e-3', default=1e-3)
training_group.add_argument('--epochs', type=int, help='number of training epochs, default: 200', default=200)
training_group.add_argument('--sequence-length', type=int, help='sequence length, default: 2000', default=2000)
training_group.add_argument('--lr-decay', type=float, help='learning rate decay factor, default: 5e-5', default=5e-5)
training_group.add_argument('--initial-checkpoint', type=str, help='initial checkpoint to start training from, default: None', default=None)
training_group.add_argument('--gamma', type=float, help='perceptual exponent (default 0.1667)', default=0.1667)
training_group.add_argument('--activity-loss-weight', type=float, help='weight for activity (VAD/guitar prob) loss (default 0.0005)', default=0.0005)
training_group.add_argument('--disable-activity-head', action='store_true', help='disable activity probability loss/head (still runs model but zero weight)')
training_group.add_argument('--save-batch-interval', type=int, help='Save partial checkpoint every N batches (0=disable)', default=0)

args = parser.parse_args()



class RNNoiseDataset(torch.utils.data.Dataset):
    def __init__(self,
                features_file,
                sequence_length=2000):

        self.sequence_length = sequence_length
        self.data = np.memmap(features_file, dtype='float32', mode='r')
        # Infer dimensionality: prefer new 99 (65 feats + 32 gains + 1 vad + 1 guitar) over legacy 98
        candidates = []
        for d in (99, 98):
            total_frames = self.data.shape[0] / d
            if abs(total_frames - int(total_frames)) < 1e-6:
                candidates.append((d, int(total_frames)))
        if not candidates:
            raise ValueError(f"Unable to infer feature dimension from file size={self.data.shape[0]}; expected multiple of 98 or 99")
        # If both match (rare but possible when length is LCM multiple), pick higher dimension (new format)
        self.dim, frames = sorted(candidates, key=lambda x: (-x[0], -x[1]))[0]

        self.nb_sequences = self.data.shape[0]//(self.sequence_length*self.dim)
        self.data = self.data[:self.nb_sequences*self.sequence_length*self.dim]
        self.data = np.reshape(self.data, (self.nb_sequences, self.sequence_length, self.dim))

    def __len__(self):
        return self.nb_sequences

    def __getitem__(self, index):
        # Layout (legacy 98): [65 feat][32 gains][1 vad]
        # Layout (new 99):    [65 feat][32 gains][1 vad][1 guitar_prob]
        if self.dim == 98:
            feats = self.data[index, :, :65]
            gains = self.data[index, :, 65:-1]
            vad = self.data[index, :, -1:]
            guitar = vad  # no separate channel
        else:  # 99
            feats = self.data[index, :, :65]
            gains = self.data[index, :, 65:-2]
            vad = self.data[index, :, -2:-1]
            guitar = self.data[index, :, -1:]
        return feats.copy(), gains.copy(), vad.copy(), guitar.copy()

def mask(g):
    return torch.clamp(g+1, max=1)

adam_betas = [0.8, 0.98]
adam_eps = 1e-8
batch_size = args.batch_size
lr = args.lr
epochs = args.epochs
sequence_length = args.sequence_length
lr_decay = args.lr_decay

cond_size  = args.cond_size
gru_size  = args.gru_size

checkpoint_dir = os.path.join(args.output, 'checkpoints')
os.makedirs(checkpoint_dir, exist_ok=True)
checkpoint = dict()

disable_cudnn_env = os.environ.get('DISABLE_CUDNN') == '1'
if disable_cudnn_env:
    torch.backends.cudnn.enabled = False

device = torch.device("cuda") if (torch.cuda.is_available() and not disable_cudnn_env and not False and not None) else torch.device("cpu")
if args.force_cpu:
    device = torch.device('cpu')
print(f"[train_rnnoise] Device selected: {device}, cuda_available={torch.cuda.is_available()}, cudnn_enabled={torch.backends.cudnn.enabled}, force_cpu={args.force_cpu}")
print(f"[train_rnnoise] Device selected: {device}, cuda_available={torch.cuda.is_available()}, cudnn_enabled={torch.backends.cudnn.enabled}")
if torch.cuda.is_available():
    try:
        print(f"[train_rnnoise] CUDA device name: {torch.cuda.get_device_name(0)}")
        torch.cuda.empty_cache()
    except Exception as _e:
        print(f"[train_rnnoise] Warning: unable to query CUDA device name: {_e}")

checkpoint['model_args']    = ()
checkpoint['model_kwargs']  = {'cond_size': cond_size, 'gru_size': gru_size}
model = rnnoise.RNNoise(*checkpoint['model_args'], **checkpoint['model_kwargs'])

if type(args.initial_checkpoint) != type(None):
    checkpoint = torch.load(args.initial_checkpoint, map_location='cpu')
    model.load_state_dict(checkpoint['state_dict'], strict=False)

checkpoint['state_dict']    = model.state_dict()

dataset = RNNoiseDataset(args.features)
print(f"[train_rnnoise] Detected feature dimension={dataset.dim} (frames per sequence candidate)")
workers = args.workers
import platform
if platform.system().lower().startswith('win') and workers > 0:
    # Windows spawn + memmap + large objects can cause pickling errors; fall back to single-process loading.
    workers = 0
    print("[train_rnnoise] Forcing workers=0 on Windows to avoid multiprocessing pickle issues.")

dataloader = torch.utils.data.DataLoader(
    dataset,
    batch_size=batch_size,
    shuffle=True,
    drop_last=True,
    num_workers=workers,
    pin_memory=(torch.cuda.is_available() and workers > 0)
)


optimizer = torch.optim.AdamW(model.parameters(), lr=lr, betas=adam_betas, eps=adam_eps)


# learning rate scheduler
scheduler = torch.optim.lr_scheduler.LambdaLR(optimizer=optimizer, lr_lambda=lambda x : 1 / (1 + lr_decay * x))

gamma = args.gamma

if __name__ == '__main__':
    model.to(device)
    states = None
    save_batch_interval = max(0, int(args.save_batch_interval))
    warmup_done = False
    for epoch in range(1, epochs + 1):
        running_gain_loss = 0
        running_vad_loss = 0
        running_loss = 0

        print(f"training epoch {epoch}...")
        with tqdm.tqdm(dataloader, unit='batch') as tepoch:
            for i, batch in enumerate(tepoch):
                # Backward compatibility: batch may have 3 or 4 tensors
                if len(batch) == 3:
                    features, gain, vad = batch
                    guitar = vad
                else:
                    features, gain, vad, guitar = batch
                # Optional warmup modifications only for very first batch overall
                if not warmup_done and i == 0:
                    if args.warmup_batch_size > 0 and features.size(0) > args.warmup_batch_size:
                        features = features[:args.warmup_batch_size]
                        gain = gain[:args.warmup_batch_size]
                        vad = vad[:args.warmup_batch_size]
                        guitar = guitar[:args.warmup_batch_size]
                    if args.warmup_seq_len > 0 and features.size(1) > args.warmup_seq_len:
                        features = features[:, :args.warmup_seq_len]
                        gain = gain[:, :args.warmup_seq_len]
                        vad = vad[:, :args.warmup_seq_len]
                        guitar = guitar[:, :args.warmup_seq_len]
                    warmup_done = True
                optimizer.zero_grad()
                features = features.to(device)
                gain = gain.to(device)
                vad = vad.to(device)
                guitar = guitar.to(device)

                pred_gain, pred_vad, states = model(features, states=states)
                states = [state.detach() for state in states]
                gain = gain[:,3:-1,:]
                vad = vad[:,3:-1,:]
                guitar = guitar[:,3:-1,:]
                target_gain = torch.clamp(gain, min=0)
                target_gain = target_gain*(torch.tanh(5*target_gain)**2)

                gain_loss = torch.mean(mask(gain)*(pred_gain**gamma - target_gain**gamma)**2)
                #vad_loss = torch.mean(torch.abs(2*vad-1)*(vad-pred_vad)**2)
                # Choose which activity label to supervise against
                activity_label = guitar if (args.use_guitar_activity_label and dataset.dim == 99) else vad
                vad_loss = torch.mean(torch.abs(2*activity_label-1)*(-activity_label*torch.log(.01+pred_vad) - (1-activity_label)*torch.log(1.01-pred_vad)))
                # Optionally disable or reweight activity loss
                activity_w = 0.0 if args.disable_activity_head else args.activity_loss_weight
                loss = gain_loss + activity_w*vad_loss

                try:
                    loss.backward()
                except RuntimeError as rt_err:
                    print(f"[train_rnnoise] Backward pass error at epoch={epoch} batch={i}: {rt_err}")
                    fallback_success = False
                    if device.type == 'cuda':
                        print('[train_rnnoise] Attempting safe GPU -> CPU fallback (resetting optimizer, states).')
                        # Try to sync to surface any latent errors; ignore if it fails.
                        try:
                            torch.cuda.synchronize()
                        except Exception as _se:
                            print(f"[train_rnnoise] cuda.synchronize() failed (ignored): {_se}")
                        # Capture state_dict if possible
                        sd = None
                        try:
                            sd = {k: v.detach().cpu() for k,v in model.state_dict().items()}
                        except Exception as _sd_e:
                            print(f"[train_rnnoise] Could not snapshot GPU state_dict (continuing with fresh model): {_sd_e}")
                        # Move tensors to CPU (guard each)
                        def to_cpu_safe(t):
                            try:
                                return t.detach().cpu()
                            except Exception as _tc_e:
                                print(f"[train_rnnoise] Tensor CPU transfer failed (will re-generate): {_tc_e}")
                                return None
                        features = to_cpu_safe(features) or features.new_tensor(features.cpu())
                        gain = to_cpu_safe(gain) or gain.new_tensor(gain.cpu())
                        vad = to_cpu_safe(vad) or vad.new_tensor(vad.cpu())
                        guitar = to_cpu_safe(guitar) or guitar.new_tensor(guitar.cpu())
                        states = None  # Reset recurrent states after device fault
                        # Rebuild model fresh on CPU
                        try:
                            cpu_model = rnnoise.RNNoise(*checkpoint['model_args'], **checkpoint['model_kwargs'])
                            if sd is not None:
                                missing, unexpected = cpu_model.load_state_dict(sd, strict=False)
                                if missing or unexpected:
                                    print(f"[train_rnnoise] Warning: state load missing={missing} unexpected={unexpected}")
                            model = cpu_model
                            device = torch.device('cpu')
                            torch.backends.cudnn.enabled = False
                            # Rebuild optimizer & scheduler for CPU params (retain LR progression via scheduler.last_epoch)
                            last_epoch = scheduler.last_epoch if 'scheduler' in locals() else -1
                            optimizer = torch.optim.AdamW(model.parameters(), lr=lr, betas=adam_betas, eps=adam_eps)
                            scheduler = torch.optim.lr_scheduler.LambdaLR(optimizer=optimizer, lr_lambda=lambda x : 1 / (1 + lr_decay * x))
                            # Advance scheduler to previous epoch *approx* progress
                            for _k in range(last_epoch + 1):
                                scheduler.step()
                            optimizer.zero_grad(set_to_none=True)
                            # Recompute forward on CPU
                            pred_gain, pred_vad, states = model(features, states=None)
                            gain_loss = torch.mean(mask(gain)*(pred_gain**gamma - target_gain**gamma)**2)
                            activity_label = guitar if (args.use_guitar_activity_label and dataset.dim == 99) else vad
                            vad_loss = torch.mean(torch.abs(2*activity_label-1)*(-activity_label*torch.log(.01+pred_vad) - (1-activity_label)*torch.log(1.01-pred_vad)))
                            activity_w = 0.0 if args.disable_activity_head else args.activity_loss_weight
                            loss = gain_loss + activity_w*vad_loss
                            loss.backward()
                            fallback_success = True
                            print('[train_rnnoise] CPU fallback succeeded; continuing training on CPU.')
                        except Exception as fb_e:
                            print(f"[train_rnnoise] CPU fallback failed: {fb_e}")
                            fallback_success = False
                    if not fallback_success:
                        print('[train_rnnoise] Aborting due to unrecoverable backward error.')
                        raise
                optimizer.step()
                model.sparsify()

                scheduler.step()

                running_gain_loss += gain_loss.detach().cpu().item()
                running_vad_loss += vad_loss.detach().cpu().item()
                running_loss += loss.detach().cpu().item()
                tepoch.set_postfix(loss=f"{running_loss/(i+1):8.5f}",
                                   gain_loss=f"{running_gain_loss/(i+1):8.5f}",
                                   vad_loss=(f"{running_vad_loss/(i+1):8.5f}" if activity_w>0 else 'disabled'),
                                   act_w=f"{activity_w}")

                if save_batch_interval > 0 and (i+1) % save_batch_interval == 0:
                    # Partial checkpoint inside epoch
                    partial_path = os.path.join(checkpoint_dir, f'rnnoise{args.suffix}_ep{epoch}_b{i+1}.pth')
                    checkpoint['state_dict'] = model.state_dict()
                    checkpoint['loss'] = running_loss / (i+1)
                    checkpoint['epoch'] = epoch
                    checkpoint['batch'] = i+1
                    torch.save(checkpoint, partial_path)
                    if (i+1) == save_batch_interval:
                        print(f"[train_rnnoise] Saved first partial checkpoint: {partial_path}")
                    else:
                        print(f"[train_rnnoise] Saved partial checkpoint: {partial_path}")

        # save checkpoint
        checkpoint_path = os.path.join(checkpoint_dir, f'rnnoise{args.suffix}_{epoch}.pth')
        checkpoint['state_dict'] = model.state_dict()
        checkpoint['loss'] = running_loss / len(dataloader)
        checkpoint['epoch'] = epoch
        torch.save(checkpoint, checkpoint_path)
        if epoch == epochs and args.export_onnx:
            try:
                model.eval()
                # Build export wrapper exposing recurrent states explicitly
                class _ExportWrapper(nn.Module):
                    def __init__(self, core):
                        super().__init__()
                        self.core = core
                    def forward(self, features, state1, state2, state3):
                        gain, vad, states = self.core(features, states=[state1, state2, state3])
                        return gain, vad, states[0], states[1], states[2]

                wrapper = _ExportWrapper(model).to(device)
                bsz = 1
                T = max(1, int(args.onnx_dummy_seq))
                dummy_feats = torch.randn(bsz, T, 65, device=device)
                dummy_state = torch.zeros(1, bsz, model.gru_size, device=device)
                inputs = (dummy_feats, dummy_state, dummy_state, dummy_state)
                input_names = ['features', 'state1', 'state2', 'state3']
                output_names = ['gain', 'vad', 'out_state1', 'out_state2', 'out_state3']
                dynamic_axes = None
                if not args.onnx_no_dynamic:
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
                    args.export_onnx,
                    input_names=input_names,
                    output_names=output_names,
                    dynamic_axes=dynamic_axes,
                    opset_version=args.onnx_opset,
                    do_constant_folding=True,
                )
                print(f"[train_rnnoise] Exported ONNX model to {args.export_onnx} (opset={args.onnx_opset}, dynamic={(dynamic_axes is not None)})")
            except Exception as e:
                print(f"[train_rnnoise] ONNX export failed: {e}")
