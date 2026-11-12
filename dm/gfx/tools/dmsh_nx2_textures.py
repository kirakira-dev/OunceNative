"""Preserve native sampled-texture register bits using the live pixel class."""
import re


def _close_call(source, opening):
    depth = 1
    for at in range(opening + 1, len(source)):
        if source[at] == '(':
            depth += 1
        elif source[at] == ')':
            depth -= 1
            if not depth:
                return at
    raise ValueError('unterminated texture operation')


def _helper(texture_type, method, rectangle, component):
    name = f'dm_{texture_type}_{method}' + ('_rect' if rectangle else '')
    if component:
        name += '_' + component
    value = method in ('sample', 'read', 'gather')
    result = 'float4' if value else 'float' if 'lod' in method and method.startswith('calculate_') else 'uint'
    args = 'A... args'
    forwarded = 'args...'
    if component:
        forwarded += ', component::' + component
    prefix = ''
    if rectangle:
        args = 'sampler s, float2 uv, A... args'
        forwarded = 's, uv, args...'
        # flags bit 2 is NVN's rectangle target; the sampler stays normalized.
        prefix = ('    if (flags & 4ul) {\n'
                  '        uint2 size = (flags & 3ul) == 1ul ? uint2(u.get_width(), u.get_height()) :\n'
                  '                     (flags & 3ul) == 2ul ? uint2(i.get_width(), i.get_height()) :\n'
                  '                                         uint2(f.get_width(), f.get_height());\n'
                  '        uv /= float2(size);\n'
                  '    }\n')
    def call(which):
        expression = f'{which}.{method}({forwarded})'
        return f'as_type<float4>({expression})' if value and which != 'f' else expression
    return name, (f'template<typename... A>\nstatic inline {result} {name}(\n'
                  f'    {texture_type}<float> f, {texture_type}<uint> u, {texture_type}<int> i,\n'
                  f'    ulong flags, {args}) {{\n' + prefix +
                  f'    if ((flags & 3ul) == 1ul) return {call("u")};\n'
                  f'    if ((flags & 3ul) == 2ul) return {call("i")};\n'
                  f'    return {call("f")};\n}}\n')


def runtime_texture_formats(source, reflection, stage):
    """Rewrite every sampled color texture or reject the unsupported use.

    The offline IR is deliberately float-shaped. Integer loads retain their
    bits, including NaN-shaped integers; only the bound NVN descriptor chooses
    which typed Metal operation executes. Fixed comparison textures stay depth.
    """
    if stage not in (0, 1, 5):
        raise ValueError('unsupported stage for deferred sampled formats')
    bindings = reflection['bindings']
    aid = max((b['arg_id'] for b in bindings), default=-1) + 1
    helpers, extra, declarations = {}, [], []
    methods = {'sample', 'read', 'gather', 'get_width', 'get_height', 'get_depth',
               'get_array_size', 'get_num_mip_levels', 'get_num_samples',
               'calculate_clamped_lod', 'calculate_unclamped_lod'}
    for binding in list(bindings):
        if binding['kind'] != 'tex' or binding['msl_type'].startswith('depth'):
            continue
        ty = re.fullmatch(r'(texture(?:1d|2d|3d|cube)(?:_array|_ms)?)<float>', binding['msl_type'])
        if not ty:
            raise ValueError('unsupported deferred texture type: ' + binding['msl_type'])
        texture_type, name = ty[1], binding['msl_name']
        declaration = re.search(r'^\s+' + re.escape(binding['msl_type']) + r'\s+' +
                                re.escape(name) + r'\s+\[\[id\(\d+\)\]\];', source, re.M)
        if not declaration:
            raise ValueError('missing deferred texture declaration: ' + name)
        pattern = re.compile(r'\b(\w+)\.' + re.escape(name) + r'\.(\w+)\(')
        calls = list(pattern.finditer(source))
        depth_casts = re.findall(r'\bspvDepthCast\(\w+\.' + re.escape(name) + r'\)', source)
        if len(re.findall(r'\b' + re.escape(name) + r'\b', source)) != len(calls) + len(depth_casts) + 1:
            raise ValueError('unresolved deferred texture use: ' + name)
        if not calls and depth_casts:
            continue
        for call in reversed(calls):
            method = call[2]
            if method not in methods:
                raise ValueError('unsupported deferred texture operation: ' + method)
            end = _close_call(source, call.end() - 1)
            args = source[call.end():end]
            component = None
            if method == 'gather':
                channel = re.search(r',\s*component::([xyzw])\s*$', args)
                if channel:
                    component = channel[1]
                    args = args[:channel.start()]
                elif 'component::' in args:
                    raise ValueError('unrecognized gather component')
            rectangle = stage == 1 and texture_type == 'texture2d' and method == 'sample' and not re.search(
                r'\b(?:level|gradient\w*)\s*\(', args)
            helper, code = _helper(texture_type, method, rectangle, component)
            helpers[helper] = code
            obj = call[1] + '.'
            prefix = f'{helper}({obj}{name}, {obj}{name}_u, {obj}{name}_i, {obj}{name}_flags'
            source = source[:call.start()] + prefix + (', ' + args if args else '') + source[end:]
        binding['runtime_class'] = 0
        for kind, suffix in ((1, 'u'), (2, 'i')):
            scalar = 'uint' if kind == 1 else 'int'
            msl_type = f'{texture_type}<{scalar}>'
            declarations.append(f'    {msl_type} {name}_{suffix} [[id({aid})]];')
            extra.append(dict(binding, msl_name=name + '_' + suffix, msl_type=msl_type,
                              arg_id=aid, runtime_class=kind))
            aid += 1
        declarations.append(f'    ulong {name}_flags [[id({aid})]];')
        extra.append(dict(kind='tex_flags', reg=binding['reg'], arg_id=aid,
                          msl_name=name + '_flags', msl_type='ulong'))
        aid += 1
    if aid > 128:
        raise ValueError(f'deferred texture arguments exceed runtime limit: {aid}')
    bindings.extend(extra)
    if declarations:
        last = list(re.finditer(r'^\s+.+\s+\w+\s+\[\[id\(\d+\)\]\];', source, re.M))[-1]
        source = source[:last.end()] + '\n' + '\n'.join(declarations) + source[last.end():]
    reflection['runtime_texture_formats'] = dict(version=1)
    marker = 'using namespace metal;'
    if marker not in source:
        raise ValueError('Metal namespace declaration missing')
    source = source.replace(marker, marker + '\n\n' + '\n'.join(helpers.values()), 1)
    return source
