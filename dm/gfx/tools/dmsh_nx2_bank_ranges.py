"""Prove indirect constant-buffer banks from bit operations and loop bounds."""
import hashlib
from pathlib import Path
import subprocess

from dmsh_nx2_spirv import _buffer_dispatchers, _instructions, _pack


def toolchain_provenance():
    from dmsh_nx2_spirv import toolchain_provenance as base_provenance
    result = base_provenance()
    result['files'][str(Path(__file__).resolve())] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    return result


def _control_flow(instructions):
    functions, locations = [], {}
    blocks = None
    block = None
    for opcode, args in instructions:
        if opcode == 54:
            blocks = {}
            functions.append(blocks)
        elif opcode == 56:
            blocks = None
            block = None
        elif opcode == 248 and blocks is not None:
            block = args[0]
            blocks[block] = []
        elif block is not None:
            blocks[block].append((opcode, args))
            if opcode == 245:
                locations[args[1]] = (blocks, block)
    return functions, locations


def _graph(blocks):
    successors, predecessors = {}, {block: set() for block in blocks}
    for block, body in blocks.items():
        if not body:
            return None
        opcode, args = body[-1]
        if opcode == 249:
            edges = set(args)
        elif opcode == 250:
            edges = set(args[1:3])
        elif opcode == 251:
            return None  # Switch literals may be 64-bit; no loop proof through these yet.
        elif opcode in (252, 253, 254, 255, 4416):
            edges = set()
        else:
            return None
        if not edges <= blocks.keys():
            return None
        successors[block] = edges
        for target in edges:
            predecessors[target].add(block)
    entry = next(iter(blocks))
    reachable, pending = set(), [entry]
    while pending:
        block = pending.pop()
        if block in reachable:
            continue
        reachable.add(block)
        pending.extend(successors[block])
    dominators = {block: ({entry} if block == entry else set(reachable)) for block in reachable}
    changed = True
    while changed:
        changed = False
        for block in reachable - {entry}:
            parents = predecessors[block] & reachable
            value = {block} | set.intersection(*(dominators[parent] for parent in parents))
            if value != dominators[block]:
                dominators[block] = value
                changed = True
    return successors, predecessors, dominators


def _loop_bounds(instructions, integers, constants, definitions):
    """Recognize a two-input loop Phi whose back edge requires next < bound.

    The false successor has only the guarding branch as a predecessor and
    dominates the latch. Thus every back edge satisfies the unsigned bound.
    Together with the constant initial value, this is an inductive invariant.
    No assumption about the loop trip count or shader inputs is required.
    """
    functions, locations = _control_flow(instructions)
    graphs = {id(blocks): _graph(blocks) for blocks in functions}
    result = {}
    for value, (blocks, header) in locations.items():
        definition = definitions.get(value)
        graph = graphs[id(blocks)]
        if not graph or not definition:
            continue
        opcode, args = definition
        if opcode != 245 or len(args) != 6 or args[0] not in integers:
            continue
        successors, predecessors, dominators = graph
        if header not in dominators:
            continue
        merges = [args for op, args in blocks[header] if op == 246]
        if len(merges) != 1 or len(merges[0]) < 3:
            continue
        merge, latch = merges[0][:2]
        incoming = dict(zip(args[3::2], args[2::2]))
        if len(incoming) != 2 or latch not in incoming or set(incoming) != predecessors[header]:
            continue
        preheader = next(parent for parent in incoming if parent != latch)
        initial = constants.get(incoming[preheader])
        update = incoming[latch]
        if (initial is None or latch not in dominators or preheader not in dominators or
                header not in dominators[latch] or header in dominators[preheader]):
            continue
        for guard, body in blocks.items():
            op, branch = body[-1]
            if op != 250 or len(branch) < 3 or branch[1] != merge:
                continue
            condition = definitions.get(branch[0])
            if not condition or condition[0] != 174 or len(condition[1]) != 4:
                continue  # OpUGreaterThanEqual
            compared, limit = condition[1][2:]
            bound = constants.get(limit)
            continuation = branch[2]
            if (compared != update or bound is None or not 0 <= initial < bound or
                    guard not in dominators[latch] or continuation not in dominators[latch] or
                    predecessors[continuation] != {guard}):
                continue
            result[value] = dict(phi=value, minimum=0, maximum=bound-1,
                initial=initial, initial_block=preheader, update=update,
                header=header, latch=latch, merge=merge, guard=guard,
                continuation=continuation, condition=branch[0], unsigned_bound=bound)
            break
    return result


def fold_bounded_banks(data, timeout_ms=5000):
    """Rewrite a read-only bank dispatcher only after an exact 32-bit proof."""
    import z3

    header, instructions = _instructions(data)
    integers, booleans, constants, definitions = set(), set(), {}, {}
    for opcode, args in instructions:
        if opcode == 20:
            booleans.add(args[0])
        elif opcode == 21 and args[1] == 32:
            integers.add(args[0])
        elif opcode == 43 and args[0] in integers and len(args) == 3:
            constants[args[1]] = args[2]
        typed = opcode in (12, 41, 42, 43, 44, 45, 46, 48, 49, 50, 51, 52, 55, 57, 61, 245) or 77 <= opcode <= 215
        if typed and len(args) >= 2 and args[0] in integers | booleans:
            definitions[args[1]] = (opcode, args)
    dispatchers = _buffer_dispatchers(instructions, integers, constants)
    calls = [args for opcode, args in instructions
             if opcode == 57 and len(args) == 5 and args[2] in dispatchers]
    if not calls:
        return data, []
    bounds = _loop_bounds(instructions, integers, constants, definitions)
    context = z3.Context()
    cache, constraints, used_bounds = {}, [], set()

    def unknown(value):
        return z3.BitVec(f'word_{value}', 32, ctx=context)

    def expression(value, depth=0):
        if value in cache:
            return cache[value]
        if value in constants:
            answer = z3.BitVecVal(constants[value], 32, ctx=context)
        elif value in bounds:
            answer = unknown(value)
            constraints.append(z3.ULE(answer, bounds[value]['maximum']))
            used_bounds.add(value)
        elif depth >= 256 or value not in definitions:
            answer = unknown(value)
        else:
            opcode, args = definitions[value]
            operands = args[2:]
            get = lambda index: expression(operands[index], depth+1)
            if opcode in (128, 130, 132) and len(operands) == 2:
                a, b = get(0), get(1)
                answer = a+b if opcode == 128 else a-b if opcode == 130 else a*b
            elif opcode in (194, 196) and len(operands) == 2 and constants.get(operands[1], 32) < 32:
                answer = z3.LShR(get(0), constants[operands[1]]) if opcode == 194 else get(0) << constants[operands[1]]
            elif opcode in (197, 198, 199) and len(operands) == 2:
                a, b = get(0), get(1)
                answer = a | b if opcode == 197 else a ^ b if opcode == 198 else a & b
            elif opcode == 200 and len(operands) == 1:
                answer = ~get(0)
            elif opcode == 203 and len(operands) == 3 and all(x in constants for x in operands[1:]):
                start, count = constants[operands[1]], constants[operands[2]]
                if start <= 32 and count <= 32-start:
                    answer = (z3.BitVecVal(0, 32, ctx=context) if count == 0 else
                              z3.ZeroExt(32-count, z3.Extract(start+count-1, start, get(0))))
                else:
                    answer = unknown(value)
            elif opcode in (83, 124) and len(operands) == 1 and (
                    operands[0] in definitions and definitions[operands[0]][1][0] in integers):
                answer = get(0)
            else:
                answer = unknown(value)
        cache[value] = answer
        return answer

    resolved, proofs = {}, []
    for args in calls:
        selector = args[3]
        if selector in resolved:
            continue
        expr = expression(selector)
        solver = z3.Solver(ctx=context)
        solver.set(timeout=timeout_ms)
        solver.add(*constraints)
        if solver.check() != z3.sat:
            continue
        candidate = solver.model().eval(expr, model_completion=True).as_long()
        solver.add(expr != candidate)
        formula = solver.to_smt2()
        if solver.check() != z3.unsat:
            continue
        resolved[selector] = candidate
        proofs.append(dict(selector=selector, bank=candidate, result='unsat',
                           solver='Z3 ' + z3.get_version_string(), smt2=formula,
                           loop_invariants=[bounds[value] for value in sorted(used_bounds)]))
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


def prepare(source, destination):
    """Save a separate validated module and return its reproducible proof record."""
    source, destination = Path(source), Path(destination)
    if source.resolve() == destination.resolve():
        raise ValueError('range folding must not overwrite its source')
    subprocess.run(['spirv-val', '--target-env', 'vulkan1.2', str(source)],
                   check=True, capture_output=True, text=True)
    original = source.read_bytes()
    rewritten, proofs = fold_bounded_banks(original)
    if not proofs:
        raise ValueError('no indirect bank selector was proved constant')
    intermediate = destination.with_suffix('.before-dce.spv')
    intermediate.write_bytes(rewritten)
    flags = ['--eliminate-dead-functions', '--eliminate-dead-code-aggressive',
             '--eliminate-dead-variables', '--eliminate-dead-const']
    for command in (['spirv-val', '--target-env', 'vulkan1.2', str(intermediate)],
                    ['spirv-opt', *flags, str(intermediate), '-o', str(destination)],
                    ['spirv-val', '--target-env', 'vulkan1.2', str(destination)]):
        subprocess.run(command, check=True, capture_output=True, text=True)
    return dict(input_sha256=hashlib.sha256(original).hexdigest(),
                output_sha256=hashlib.sha256(destination.read_bytes()).hexdigest(),
                producer_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                proofs=proofs, optimizer_flags=flags)
