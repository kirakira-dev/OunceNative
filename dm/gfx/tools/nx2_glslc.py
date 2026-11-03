"""Read GLSLC reflection. Synthetic descriptor handles are used only during translation."""
import hashlib
import struct


# GLSLC reflection types present in the owned SDK 20.5.25 archive. Dimensions
# agree with native texture instructions and the captured NVN descriptors.
# Values: Shader::TextureType, integer sampling. Pixel format is deliberately
# absent: Metal supports native SNORM buffer fetches and does not need it here.
RESOURCE_TYPES = {
    0x43: (2, False),  # sampler2D
    0x44: (4, False),  # sampler3D
    0x45: (5, False),  # samplerCube
    0x47: (2, False),  # sampler2DShadow
    0x49: (3, False),  # sampler2DArray
    0x4b: (3, False),  # sampler2DArrayShadow
    0x4f: (7, False),  # samplerBuffer
    0x5a: (7, True),   # isamplerBuffer
    0x5d: (2, True),   # usampler2D
    0x64: (7, True),   # usamplerBuffer
    0x67: (2, False),  # image2D
    0x68: (4, False),  # image3D
    0x6d: (3, False),  # image2DArray
    0x7d: (2, True),   # uimage2D
    0x87: (6, False),  # samplerCubeArray
    0x8a: (6, False),  # samplerCubeArrayShadow
}


def parse(blob):
    def u32(offset):
        if offset < 0 or offset + 4 > len(blob):
            raise ValueError('GLSLC word outside object')
        return struct.unpack_from('<I', blob, offset)[0]

    if u32(0) != 0x19866891 or u32(8) not in (0x220015, 0x220615):
        raise ValueError('unsupported GLSLC version')
    if u32(0x5c) != len(blob) or u32(0x148) != 3:
        raise ValueError('unsupported GLSLC reflection header')
    co = u32(0x60)
    size, used, c1size, c1off, allocated = [u32(co+x) for x in (0x30, 0x38, 0x3c, 0x40, 0x44)]
    stage = u32(co+0x54) >> 16
    if (u32(co) != 0x98761234 or size < 0xd8 or stage > 5 or
            used > allocated or c1off+c1size > allocated or co+size+allocated > len(blob)):
        raise ValueError('invalid GLSLC shader sections')
    control = blob[co:co+size]
    code = blob[co+size:co+size+used]
    c1 = blob[co+size+c1off:co+size+c1off+c1size]
    key = hashlib.sha256(control+code+c1).hexdigest()[:16]

    r, rs = u32(0x144), u32(0x140)
    count, offset, strings = u32(0x174), u32(0x178), u32(0x1a8)
    if (r+rs > len(blob) or u32(r) != 0x19292919 or
            offset+count*0xa4 > rs or strings > rs):
        raise ValueError('invalid GLSLC reflection bounds')
    resources = []
    for i in range(count):
        at = r+offset+0xa4*i
        kind = u32(at+0x70)
        if not kind or not (u32(at+0x44) & (1 << stage)):
            continue
        if kind not in (1, 2):
            raise ValueError(f'unsupported GLSLC resource kind {kind}')
        nameoff, namelen = u32(at), u32(at+4)
        if nameoff+namelen > rs-strings:
            raise ValueError('GLSLC name outside string table')
        name = blob[r+strings+nameoff:r+strings+nameoff+namelen].rstrip(b'\0').decode()
        binding = u32(at+0x48+4*stage)
        if binding == 0xffffffff:
            raise ValueError(f'active resource has no binding: {name}')
        resources.append(dict(name=name, glslc_type=u32(at+0x28), kind=kind,
                              binding=binding, count=u32(at+0x34)))
    return dict(key=key, stage=stage, control=control, code=code, c1=c1, resources=resources)


def tessellation_state(control, hull_control=None):
    """Resolve SDK tessellation declarations, with evaluation-stage precedence."""
    controls = [control] if hull_control is None else [hull_control, control]
    if hull_control is not None and (
            struct.unpack_from('<I', hull_control, 0x54)[0] >> 16 != 3 or
            struct.unpack_from('<I', control, 0x54)[0] >> 16 != 4):
        raise ValueError('tessellation pair must be hull followed by domain')
    values = [4, 0x202, 0, 0x901]
    declared = [False] * 4
    for item in controls:
        stage = struct.unpack_from('<I', item, 0x54)[0] >> 16
        if stage not in (3, 4):
            raise ValueError('tessellation state requires a hull or domain control')
        fields = struct.unpack_from('<8I', item, 0x58)
        if any(flag not in (0, 1) for flag in fields[4:]):
            raise ValueError('invalid tessellation declaration flag')
        for index, flag in enumerate(fields[4:]):
            if flag:
                values[index] = fields[index]
                declared[index] = True
    # SDK v327680 0x61a678 resolves these declarations; 0x61a7ac emits
    # Maxwell domain/spacing/output bits. Its 0x901 winding maps to CW.
    domain = {4: 'triangles', 7: 'quads', 0x8e7a: 'isolines'}.get(values[0])
    spacing = {0x202: 'equal', 0x8e7b: 'fractional_odd',
               0x8e7c: 'fractional_even'}.get(values[1])
    if (domain is None or spacing is None or values[2] not in (0, 1) or
            values[3] not in (0x900, 0x901)):
        raise ValueError('unsupported tessellation declaration')
    return dict(domain=domain, spacing=spacing, point_mode=bool(values[2]),
                clockwise=values[3] == 0x901, declared=declared)


def offline_job(shader):
    control, stage = shader['control'], shader['stage']
    job = dict(key=shader['key'], control_hex=control.hex(), code_hex=shader['code'].hex(),
               cbuf={}, textures={}, facts_source='GLSLC reflection')
    if shader['c1']:
        job['c1_hex'] = shader['c1'].hex()
    if stage in (3, 4):
        job['tessellation'] = tessellation_state(control)
    if stage == 5:
        u, s, t, a, b, im, c, d = control[0xb1:0xb9]
        table_size = struct.unpack_from('<H', control, 0xba)[0]
        if a or b or c or d or table_size != 16+16*(u+s)+8*(t+im):
            raise ValueError('unsupported compute descriptor table')
        # SDK v327680: getters 0x5e7ce4/0x5e7cf0 reach QMD words 23/50
        # through 0x60e874/0x60e884. The compiler uses positive + CRS bytes.
        local_pos, local_crs, unmapped = struct.unpack_from('<3I', control, 0x68)
        if unmapped or local_pos >= 1 << 20 or local_crs >= 1 << 20:
            raise ValueError('unsupported compute local-memory allocation')
        job.update(local=list(struct.unpack_from('<3I', control, 0x58)),
                   shared=struct.unpack_from('<I', control, 0x64)[0],
                   local_memory=local_pos+local_crs)
        bank, tex_base, image_base = 0, 16+16*(u+s), 16+16*(u+s)+8*t
    else:
        bank, tex_base, image_base = 2, 0x20, None
    for resource in shader['resources']:
        typ = RESOURCE_TYPES.get(resource['glslc_type'])
        if typ is None:
            raise ValueError(f'unknown GLSLC resource type {resource["glslc_type"]:#x}')
        count, slot = resource['count'], resource['binding']
        if not 0 < count <= 128 or slot+count > 128:
            raise ValueError('GLSLC resource array outside NVN slots')
        base = tex_base if resource['kind'] == 1 else image_base
        if base is None:
            raise ValueError('graphics image descriptor table needs validation')
        if stage == 5 and slot+count > (t if resource['kind'] == 1 else im):
            raise ValueError('GLSLC resource exceeds compute descriptor count')
        for index in range(count):
            off = base+8*(slot+index)
            handle = (bank << 24) | (off+1)
            cbkey = f'{bank}:{off}'
            if cbkey in job['cbuf']:
                raise ValueError('overlapping GLSLC resource bindings')
            job['cbuf'][cbkey] = handle
            job['cbuf'][f'{bank}:{off+4}'] = 0
            job['textures'][str(handle)] = dict(type=typ[0], integer=int(typ[1]))
    return job
