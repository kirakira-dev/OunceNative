"""Prove constant indirect-buffer selectors before translating SPIR-V to Metal."""
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import shutil


def toolchain_provenance():
    import z3
    paths = [Path(__file__), Path(shutil.which('spirv-opt')), Path(shutil.which('spirv-val'))]
    paths += list((Path(z3.__file__).parent / 'lib').glob('libz3.*'))
    return dict(solver='Z3 ' + z3.get_version_string(),
                files={str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths if p.is_file()})


def _instructions(data):
    if len(data) < 20 or len(data) % 4:
        raise ValueError('invalid SPIR-V size')
    words = list(struct.unpack(f'<{len(data)//4}I', data))
    if words[0] != 0x07230203:
        raise ValueError('invalid SPIR-V magic')
    result, at = [], 5
    while at < len(words):
        count, opcode = words[at] >> 16, words[at] & 0xffff
        if not count or at + count > len(words):
            raise ValueError('invalid SPIR-V instruction')
        result.append([opcode, words[at+1:at+count]])
        at += count
    return words[:5], result


def _pack(header, instructions):
    words = list(header)
    for opcode, args in instructions:
        words += [((len(args)+1) << 16) | opcode, *args]
    return struct.pack(f'<{len(words)}I', *words)


def _buffer_dispatchers(instructions, integers, constants):
    """Match the compiler's read-only switch over uniform constant-buffer banks."""
    names, pointers, uniforms, functions = {}, set(), set(), {}
    function = None
    for opcode, args in instructions:
        if opcode == 5:  # OpName
            names[args[0]] = struct.pack(f'<{len(args)-1}I', *args[1:]).split(b'\0')[0].decode()
        elif opcode == 32 and args[1] == 2:  # OpTypePointer Uniform
            pointers.add(args[0])
        elif opcode == 59 and args[0] in pointers and args[2] == 2:
            uniforms.add(args[1])
        elif opcode == 54:  # OpFunction
            function = args[1]
            functions[function] = []
        elif opcode == 56:
            function = None
        elif function is not None:
            functions[function].append((opcode, args))
    result = {}
    for fid, body in functions.items():
        if len(body) < 11 or [op for op, _ in body[:5]] != [55, 55, 248, 247, 251]:
            continue
        first, second = body[0][1], body[1][1]
        if first[0] not in integers or second[0] not in integers:
            continue
        merge, switch = body[3][1], body[4][1]
        if len(merge) != 2 or merge[1] or switch[0] != first[1] or len(switch) < 4:
            continue
        cases = {label: bank for bank, label in zip(switch[2::2], switch[3::2])}
        if len(cases) != (len(switch)-2)//2 or cases.get(switch[1]) != 0:
            continue
        tail = body[5:]
        if tail[-2:] != [(248, [merge[0]]), (255, [])]:
            continue
        blocks = tail[:-2]
        if len(blocks) != len(cases)*4:
            continue
        seen, reads, valid = set(), {}, True
        for at in range(0, len(blocks), 4):
            block = blocks[at:at+4]
            if [op for op, _ in block] != [248, 65, 61, 254]:
                valid = False
                break
            label, access, load, ret = [args for _, args in block]
            bank = cases.get(label[0])
            if (bank is None or label[0] in seen or len(access) != 5 or
                    access[2] not in uniforms or names.get(access[2]) != f'c{bank}' or
                    constants.get(access[3]) != 0 or access[4] != second[1] or
                    len(load) != 3 or load[2] != access[1] or ret != [load[1]]):
                valid = False
                break
            seen.add(label[0])
            reads[bank] = access
        if valid and seen == set(cases):
            result[fid] = reads
    return result


def fold_constant_banks(data, timeout_ms=5000):
    """Replace only selectors proven constant for every possible input bit pattern.

    Unsigned integers use exact modular arithmetic. Unsupported operations become
    independent unconstrained words, so they cannot introduce a false proof.
    Constant shifts/extracts are modeled only where SPIR-V defines the result.
    A timeout, unknown result, or counterexample leaves the input unchanged.
    """
    header, instructions = _instructions(data)
    integers, constants, definitions = set(), {}, {}
    for opcode, args in instructions:
        if opcode == 21 and args[1] == 32:
            integers.add(args[0])
        elif opcode == 43 and args[0] in integers and len(args) == 3:
            constants[args[1]] = args[2]
        typed_result = opcode in (12, 41, 42, 43, 44, 45, 46, 48, 49, 50, 51, 52, 55, 57, 61) or 77 <= opcode <= 215
        if typed_result and len(args) >= 2 and args[0] in integers:
            definitions[args[1]] = (opcode, args)
    dispatchers = _buffer_dispatchers(instructions, integers, constants)
    calls = [(args, args[3]) for opcode, args in instructions
             if opcode == 57 and len(args) == 5 and args[2] in dispatchers and args[3] not in constants]
    if not calls:
        return data, []
    import z3

    modulus = 1 << 32
    context = z3.Context()
    cache, domains = {}, []

    def unknown(value):
        word = z3.Int(f'word_{value}', ctx=context)
        domains.extend((word >= 0, word < modulus))
        return word

    def expression(value, depth=0):
        if value in cache:
            return cache[value]
        if value in constants:
            answer = z3.IntVal(constants[value], ctx=context)
        elif depth >= 256 or value not in definitions:
            answer = unknown(value)
        else:
            opcode, args = definitions[value]
            operands = args[2:]
            get = lambda index: expression(operands[index], depth+1)
            if opcode in (128, 130) and len(operands) == 2:  # IAdd / ISub
                answer = (get(0) + (get(1) if opcode == 128 else -get(1))) % modulus
            elif opcode == 132 and len(operands) == 2 and any(x in constants for x in operands):
                answer = (get(0) * get(1)) % modulus
            elif opcode in (194, 196) and len(operands) == 2 and constants.get(operands[1], 32) < 32:
                power = 1 << constants[operands[1]]
                answer = get(0) / power if opcode == 194 else (get(0) * power) % modulus
            elif opcode == 203 and len(operands) == 3 and all(x in constants for x in operands[1:]):
                start, count = constants[operands[1]], constants[operands[2]]
                answer = ((get(0) / (1 << start)) % (1 << count)
                          if start <= 32 and count <= 32-start else unknown(value))
            elif opcode in (83, 124) and len(operands) == 1 and operands[0] in definitions:
                answer = get(0)  # CopyObject / integer-to-integer Bitcast
            else:
                answer = unknown(value)
        cache[value] = answer
        return answer

    proofs, resolved = [], {}
    for args, selector in calls:
        if selector in resolved:
            continue
        expr = expression(selector)
        solver = z3.Solver(ctx=context)
        solver.set(timeout=timeout_ms)
        solver.add(*domains)
        if solver.check() != z3.sat:
            continue
        candidate = solver.model().eval(expr, model_completion=True).as_long()
        solver.add(expr != candidate)
        formula = solver.to_smt2()
        if solver.check() != z3.unsat:
            continue
        resolved[selector] = candidate
        proofs.append(dict(selector=selector, bank=candidate, result='unsat',
                           solver='Z3 ' + z3.get_version_string(), smt2=formula))
    if not resolved:
        return data, []
    rewritten = []
    for opcode, args in instructions:
        if opcode == 57 and len(args) == 5 and args[2] in dispatchers and args[3] in resolved:
            reads = dispatchers[args[2]]
            access = reads.get(resolved[args[3]], reads[0])
            pointer = header[3]
            header[3] += 1
            rewritten.append([65, [access[0], pointer, access[2], access[3], args[4]]])
            rewritten.append([61, [args[0], args[1], pointer]])
        else:
            rewritten.append([opcode, args])
    return _pack(header, rewritten), proofs


def prepare(path, metadata):
    """Return a separate optimized module; never modify the translated archive input."""
    banks = {row['slot'] for row in metadata.get('cbufs', [])}
    if not {0, 1, 2}.issubset(banks):
        return Path(path), []
    original = Path(path).read_bytes()
    rewritten, proofs = fold_constant_banks(original)
    if not proofs:
        return Path(path), []
    stem = Path(path).with_suffix('.constant-banks')
    intermediate = stem.with_suffix('.constant-banks-input.spv')
    output = stem.with_suffix('.constant-banks.spv')
    intermediate.write_bytes(rewritten)
    flags = ['--eliminate-dead-functions', '--eliminate-dead-code-aggressive',
             '--eliminate-dead-variables', '--eliminate-dead-const']
    for command in (['spirv-opt', *flags, str(intermediate), '-o', str(output)],
                    ['spirv-val', '--target-env', 'vulkan1.2', str(output)]):
        subprocess.run(command, check=True, capture_output=True, text=True)
    report = dict(input_sha256=hashlib.sha256(original).hexdigest(),
                  output_sha256=hashlib.sha256(output.read_bytes()).hexdigest(),
                  proofs=proofs, optimizer_flags=flags)
    stem.with_suffix('.constant-banks.json').write_text(json.dumps(report, indent=2))
    return output, [report]
