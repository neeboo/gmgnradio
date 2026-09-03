# ARDY Offline Motion Baker Spike

Updated: 2026-08-09

## Decision

Adopt ARDY behind an offline motion factory for path-following, gestures, dance,
and everyday activity drafts. It stays outside the macOS runtime. The current
app remains fully functional without CUDA, ARDY, a remote motion service, or a
text-encoder token.

The first integration consumes the stable motion-spec JSON returned by the
text-to-vrma ARDY service and publishes VRMA for VRM or an in-place, finger-free
VMD for PMX. It deliberately does not convert raw ARDY `.npz` output. A raw
neutral-document converter remains gated on a CUDA benchmark and verified
source-skeleton metadata.

Implemented on 2026-08-11:

- `tools/motion/gmgn_motion_factory.py`: capacity preflight, ARDY HTTP client,
  strict spec validation, deterministic VRMA/VMD builders and immutable catalog
  publisher;
- `apps/macos/Packages/MotionDistribution`: hostless catalog validation,
  same-origin download, SHA-256 verification and artifact cache;
- `RemoteMotionLibrary` plus the macOS action-library settings entry;
- safe fallback remains unchanged when no catalog or generated motion exists.
- PMX output preserves ARDY's full X/Y/Z root movement and omits finger tracks,
  so generated actions keep jumps and natural displacement without
  reintroducing finger-retargeting regressions.

## Verified upstream facts

- The official implementation supports streaming text prompts, root paths,
  waypoints, full-body keyframes, and sparse joint constraints. Its batch tool
  writes `.npz` containing world-space joint positions, local/global rotations,
  root positions, foot contacts, FPS, and prompt text. [Official ARDY repository](https://github.com/nv-tlabs/ardy)
- NVIDIA primarily tests the project on Ubuntu 22.04, RTX 4090, Python 3.11,
  NVIDIA driver 575, CUDA-compatible PyTorch 2.4 or newer. TensorRT requires a
  CUDA 12-capable driver. [Official setup documentation](https://github.com/nv-tlabs/ardy#setup)
- The text encoder uses gated `Meta-Llama-3-8B-Instruct`; the documented default
  CUDA/bfloat16 text-encoder setting uses about 14 GB VRAM. This adds a separate
  access and licensing dependency to text-conditioned generation. [Official ARDY documentation](https://github.com/nv-tlabs/ardy#tab-model)
- The released Core checkpoint is a 326M-parameter diffusion model using a
  27-joint skeleton at 20 FPS. NVIDIA lists Linux and NVIDIA GPU architectures
  as supported deployment targets. [Official NVIDIA model card](https://huggingface.co/nvidia/ARDY-Core-RP-20FPS-Horizon40)
- The code is Apache-2.0. Checkpoints use the NVIDIA Open Model Agreement, which
  allows commercial use and derivative works and does not claim ownership of
  generated outputs, subject to its redistribution and notice terms. [Code license](https://github.com/nv-tlabs/ardy/blob/main/LICENSE), [model agreement](https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-agreement/)
- NVIDIA documents foot skating, imperfect prompt following, one output skeleton
  per trained model, and no awareness of surrounding scene objects as known
  limitations. [Official NVIDIA model card](https://huggingface.co/nvidia/ARDY-Core-RP-20FPS-Horizon40#technical-limitations-and-mitigation)

## Proposed offline pipeline

```text
activity prompt + authored route/anchors
                |
                v
      ARDY on a CUDA workstation
                |
                v
 versioned neutral motion document
 joints + local rotations + root + contacts + fps
                |
                v
 Blender retarget and foot-contact correction
                |
        +-------+-------+
        |               |
        v               v
      VRMA             VMD
        |               |
        +-------+-------+
                |
                v
 world manifest resource + SHA-256 + approved motion ID
```

The later raw neutral document must include:

- ARDY checkpoint ID and license identifier;
- generation prompt, seed, FPS, duration, and generation timestamp;
- source skeleton joint names, parent indices, bind transforms, and coordinate
  convention;
- per-frame local joint rotations and root transform;
- left/right foot contacts;
- authored route, anchor, and target-facing constraints;
- converter and retarget profile versions.

## Benchmark required before adoption

Run on an approved Linux/CUDA workstation with both Core horizon variants and
generate at least five seeds for each first-release activity:

- walk a supplied kitchen route;
- turn and face an authored target;
- gaze through a window;
- listen beside a speaker;
- sit at a chair anchor;
- dance within a marked stage area.

Measure:

| Metric | Gate |
| --- | --- |
| Batch latency | Record p50/p95; no shipping runtime dependency |
| Route error | Root stays within 8 cm of authored path after retarget |
| Anchor error | Final root within 8 cm and feet within 3 cm of ground |
| Foot sliding | No visible planted-foot drift above 3 cm |
| Skeleton integrity | No non-finite transforms, joint stretch, finger explosion, or neck/shoulder distortion |
| Loop quality | Idle/listen/dance loop seam has no visible pop |
| Retarget parity | Both approved VRM and PMX canaries pass the same scripted review |
| Licensing | Code, model, text encoder, and generated-asset notices reviewed before distribution |

## Integration boundary

ARDY output may enter the repository only as a reviewed, versioned motion
resource with a SHA-256 hash and an explicit activity motion ID. The Agent and
renderer never call ARDY per frame. Missing or rejected generated assets follow
the current natural-idle fallback, so world simulation and Live Cam remain
deterministic.
