"""Derive a finite low-button reach/press/retract from locally licensed poses.

The installed pickup pose supplies the reach geometry. The derived action is
packaged with its source identity/hash; it holds contact, adds a wrist press,
and returns to its initial pose instead of carrying an object away. Distribution
of the derived resource remains subject to the original asset's license.
"""
import argparse
import hashlib
import json
import math
import struct
from pathlib import Path

CONTACT = 1.54
PRESS_END = 1.84
DURATION = 3.38


def source_time(t):
    if t <= CONTACT:
        return t
    if t <= PRESS_END:
        return CONTACT
    return max(0, CONTACT - (t - PRESS_END))


def sample(times, values, time, quaternion=False):
    index = next((i for i, t in enumerate(times) if t >= time), len(times) - 1)
    if index == 0:
        return values[0]
    amount = (time - times[index - 1]) / max(1e-9, times[index] - times[index - 1])
    a, b = values[index - 1], values[index]
    if quaternion and sum(x*y for x, y in zip(a, b)) < 0:
        b = [-x for x in b]
    result = [x + (y-x)*amount for x, y in zip(a, b)]
    if quaternion:
        length = math.sqrt(sum(x*x for x in result))
        result = [x/length for x in result]
    return result


def derive_vrma(data):
    json_length = struct.unpack_from('<I', data, 12)[0]
    document = json.loads(data[20:20+json_length])
    binary_offset = 20+json_length+8
    original = data[binary_offset:]
    binary = bytearray(original)
    times = sorted(set([i/30 for i in range(102)] + [CONTACT, PRESS_END, DURATION]))

    def read(index):
        accessor = document['accessors'][index]
        view = document['bufferViews'][accessor['bufferView']]
        width = {'SCALAR': 1, 'VEC3': 3, 'VEC4': 4}[accessor['type']]
        if accessor['componentType'] != 5126 or view.get('byteStride'):
            raise ValueError('Expected packed float animation accessor')
        offset = view.get('byteOffset', 0) + accessor.get('byteOffset', 0)
        return [list(struct.unpack_from('<'+'f'*width, original, offset+i*width*4))
                for i in range(accessor['count'])]

    def append(values, kind):
        while len(binary) % 4:
            binary.append(0)
        offset = len(binary)
        flattened = [x for value in values for x in value]
        binary.extend(struct.pack('<'+'f'*len(flattened), *flattened))
        document['bufferViews'].append({'buffer': 0, 'byteOffset': offset, 'byteLength': len(flattened)*4})
        accessor = {'bufferView': len(document['bufferViews'])-1, 'componentType': 5126,
                    'count': len(values), 'type': kind}
        if kind == 'SCALAR':
            accessor.update(min=[values[0][0]], max=[values[-1][0]])
        document['accessors'].append(accessor)
        return len(document['accessors'])-1

    animation = document['animations'][0]
    press_nodes = {value['node'] for name, value in document['extensions']['VRMC_vrm_animation']['humanoid']['humanBones'].items()
                   if name == 'rightHand'}
    for sampler_index, sampler in enumerate(animation['samplers']):
        old_times = [x[0] for x in read(sampler['input'])]
        old_values = read(sampler['output'])
        kind = document['accessors'][sampler['output']]['type']
        sampler['input'] = append([[t] for t in times], 'SCALAR')
        values = [sample(old_times, old_values, source_time(t), kind == 'VEC4') for t in times]
        if any(channel['sampler'] == sampler_index and channel['target']['node'] in press_nodes
               for channel in animation['channels']):
            for t, value in zip(times, values):
                pulse = math.sin(math.pi * (t-CONTACT)/(PRESS_END-CONTACT)) if CONTACT < t < PRESS_END else 0
                angle = pulse * .12
                s, c = math.sin(angle/2), math.cos(angle/2)
                x, y, z, w = value
                value[:] = [c*x+s*w, c*y-s*z, c*z+s*y, c*w-s*x]
        sampler['output'] = append(values, kind)
        sampler['interpolation'] = 'LINEAR'
    document['asset']['generator'] = 'gmgn-jukebox-low-button/1 reach-hold-retract'
    document['buffers'][0]['byteLength'] = len(binary)
    encoded = json.dumps(document, separators=(',', ':')).encode()
    encoded += b' ' * (-len(encoded) % 4)
    binary += b'\0' * (-len(binary) % 4)
    return struct.pack('<III', 0x46546c67, 2, 28+len(encoded)+len(binary)) + struct.pack('<II', len(encoded), 0x4e4f534a) + encoded + struct.pack('<II', len(binary), 0x004e4942) + binary


def derive_vmd(data):
    count = struct.unpack_from('<I', data, 50)[0]
    tracks = {}
    for i in range(count):
        record = data[54+i*111:54+(i+1)*111]
        frame = struct.unpack_from('<I', record, 15)[0]
        tracks.setdefault(record[:15], []).append((frame/30, record))
    frames = []
    for name, keys in tracks.items():
        keys.sort(key=lambda x: x[0])
        times = [t for t, _ in keys]
        positions = [struct.unpack_from('<3f', record, 19) for _, record in keys]
        rotations = [struct.unpack_from('<4f', record, 31) for _, record in keys]
        for frame in range(103):
            t = min(frame/30, DURATION)
            position = sample(times, positions, source_time(t))
            rotation = sample(times, rotations, source_time(t), True)
            if name.rstrip(b'\0').decode('cp932') == '右手首':
                pulse = math.sin(math.pi*(t-CONTACT)/(PRESS_END-CONTACT)) if CONTACT < t < PRESS_END else 0
                s, c = math.sin(pulse*.12/2), math.cos(pulse*.12/2)
                x, y, z, w = rotation
                rotation = [c*x+s*w, c*y-s*z, c*z+s*y, c*w-s*x]
            frames.append(name + struct.pack('<I3f4f', frame, *position, *rotation) + keys[0][1][47:111])
    # Finite bone-only action; no inherited object/morph/camera side effects.
    return data[:50] + struct.pack('<I', len(frames)) + b''.join(frames) + struct.pack('<5I', 0, 0, 0, 0, 0)


def build(root, bundle=None):
    for avatar, extension, derive in [('vrm', 'vrma', derive_vrma), ('pmx', 'vmd', derive_vmd)]:
        source = root / ('gmgn.motion.bones.arpg.pickup-standing-' + avatar)
        manifest = json.loads((source/'manifest.json').read_text())
        raw = (source/manifest['entry']).read_bytes()
        if hashlib.sha256(raw).hexdigest() != manifest['sha256']:
            raise ValueError('Installed source hash mismatch')
        motion_id = 'gmgn.motion.device.jukebox-low-button-' + avatar
        output = root/motion_id
        output.mkdir(exist_ok=True)
        asset = derive(raw)
        entry = motion_id + '.' + extension
        (output/entry).write_bytes(asset)
        published = {'id': motion_id, 'name': '低位按钮操作', 'format': extension,
                     'entry': entry, 'version': '1.0.0', 'loop': False,
                     'playbackRate': 1, 'inPlace': False, 'sha256': hashlib.sha256(asset).hexdigest(),
                     'derivation': {'sourceID': manifest['id'], 'sourceSHA256': manifest['sha256'],
                                    'contactSeconds': CONTACT, 'pressEndSeconds': PRESS_END,
                                    'durationSeconds': DURATION, 'phases': ['reach', 'press-hold', 'retract']}}
        (output/'manifest.json').write_text(json.dumps(published, ensure_ascii=False, indent=2)+'\n')
        if bundle is not None:
            bundle.mkdir(parents=True, exist_ok=True)
            (bundle/entry).write_bytes(asset)
            (bundle/(motion_id+'.json')).write_text(json.dumps(published, ensure_ascii=False, indent=2)+'\n')
        print(motion_id, published['sha256'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--motion-root', type=Path, required=True)
    parser.add_argument('--bundle-output', type=Path)
    args = parser.parse_args()
    build(args.motion_root, args.bundle_output)
