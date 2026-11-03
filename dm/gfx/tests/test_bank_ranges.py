"""Positive and rejection cases for bounded indirect constant-buffer reads."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from dmsh_nx2_bank_ranges import fold_bounded_banks
from dmsh_nx2_spirv import _instructions, _pack
from test_constant_banks import ConstantBankTests, module


def shader_source(loop=False, *, initial=0, bound=13, signed=False, bypass=False,
                  compare_update=True):
    source = '''OpCapability Shader
OpMemoryModel Logical GLSL450
OpEntryPoint GLCompute %main "main" %gid %outbuf %inputs %c0 %c1 %c2
OpExecutionMode %main LocalSize 64 1 1
OpName %c0 "c0"
OpName %c1 "c1"
OpName %c2 "c2"
OpName %outbuf "outbuf"
OpName %inputs "inputs"
OpDecorate %gid BuiltIn GlobalInvocationId
OpDecorate %array ArrayStride 16
OpDecorate %block Block
OpMemberDecorate %block 0 Offset 0
OpDecorate %results ArrayStride 16
OpDecorate %outputblock Block
OpMemberDecorate %outputblock 0 Offset 0
OpDecorate %words ArrayStride 4
OpDecorate %inputblock Block
OpMemberDecorate %inputblock 0 Offset 0
OpDecorate %c0 DescriptorSet 0
OpDecorate %c0 Binding 0
OpDecorate %c1 DescriptorSet 0
OpDecorate %c1 Binding 1
OpDecorate %c2 DescriptorSet 0
OpDecorate %c2 Binding 2
OpDecorate %outbuf DescriptorSet 0
OpDecorate %outbuf Binding 3
OpDecorate %inputs DescriptorSet 0
OpDecorate %inputs Binding 4
OpDecorate %inputs NonWritable
%void = OpTypeVoid
%bool = OpTypeBool
%u32 = OpTypeInt 32 0
%v3u = OpTypeVector %u32 3
%v4u = OpTypeVector %u32 4
%zero = OpConstant %u32 0
%one = OpConstant %u32 1
%two = OpConstant %u32 2
%four = OpConstant %u32 4
%sixteen = OpConstant %u32 16
%initial = OpConstant %u32 INITIAL
%bound = OpConstant %u32 BOUND
%bankone = OpConstant %u32 65536
%true = OpConstantTrue %bool
%array = OpTypeArray %v4u %sixteen
%block = OpTypeStruct %array
%blockptr = OpTypePointer Uniform %block
%vecptr = OpTypePointer Uniform %v4u
%inputptr = OpTypePointer Input %v3u
%results = OpTypeRuntimeArray %v4u
%outputblock = OpTypeStruct %results
%outputptr = OpTypePointer StorageBuffer %outputblock
%outputvecptr = OpTypePointer StorageBuffer %v4u
%words = OpTypeRuntimeArray %u32
%inputblock = OpTypeStruct %words
%inputblockptr = OpTypePointer StorageBuffer %inputblock
%wordptr = OpTypePointer StorageBuffer %u32
%c0 = OpVariable %blockptr Uniform
%c1 = OpVariable %blockptr Uniform
%c2 = OpVariable %blockptr Uniform
%outbuf = OpVariable %outputptr StorageBuffer
%inputs = OpVariable %inputblockptr StorageBuffer
%gid = OpVariable %inputptr Input
%loadtype = OpTypeFunction %v4u %u32 %u32
%maintype = OpTypeFunction %void
%load = OpFunction %v4u None %loadtype
%bank = OpFunctionParameter %u32
%offset = OpFunctionParameter %u32
%entry = OpLabel
OpSelectionMerge %dispatchmerge None
OpSwitch %bank %bank0 0 %bank0 1 %bank1 2 %bank2
%bank0 = OpLabel
%pointer0 = OpAccessChain %vecptr %c0 %zero %offset
%value0 = OpLoad %v4u %pointer0
OpReturnValue %value0
%bank1 = OpLabel
%pointer1 = OpAccessChain %vecptr %c1 %zero %offset
%value1 = OpLoad %v4u %pointer1
OpReturnValue %value1
%bank2 = OpLabel
%pointer2 = OpAccessChain %vecptr %c2 %zero %offset
%value2 = OpLoad %v4u %pointer2
OpReturnValue %value2
%dispatchmerge = OpLabel
OpUnreachable
OpFunctionEnd
%main = OpFunction %void None %maintype
%start = OpLabel
%position = OpLoad %v3u %gid
%id = OpCompositeExtract %u32 %position 0
%wordpointer = OpAccessChain %wordptr %inputs %zero %id
%x = OpLoad %u32 %wordpointer
'''.replace('INITIAL', str(initial)).replace('BOUND', str(bound))
    if loop:
        source += '''OpBranch %header
%header = OpLabel
%i = OpPhi %u32 %initial %start %next %latch
OpLoopMerge %merge %latch None
OpBranch %body
%body = OpLabel
%shifted = OpShiftLeftLogical %u32 %i %four
'''
    else:
        source += '''%inverted = OpNot %u32 %x
%lo = OpBitwiseAnd %u32 %inverted %one
%half = OpShiftRightLogical %u32 %x %one
%hi = OpBitwiseAnd %u32 %half %one
%double = OpShiftLeftLogical %u32 %hi %one
%i = OpIAdd %u32 %double %lo
%shifted = OpShiftLeftLogical %u32 %i %four
'''
    source += '''%address = OpIAdd %u32 %shifted %bankone
%selector = OpBitFieldUExtract %u32 %address %sixteen %sixteen
%byteoffset = OpBitFieldUExtract %u32 %address %zero %sixteen
%wordoffset = OpShiftRightLogical %u32 %byteoffset %four
%value = OpFunctionCall %v4u %load %selector %wordoffset
'''
    source += ('''%base = OpIMul %u32 %id %bound
%index = OpIAdd %u32 %base %i
''' if loop else '%index = OpCopyObject %u32 %id\n')
    source += '''%target = OpAccessChain %outputvecptr %outbuf %zero %index
OpStore %target %value
'''
    if loop:
        source += '%next = OpIAdd %u32 %i %one\n'
        source += ('%quit = OpSGreaterThanEqual' if signed else '%quit = OpUGreaterThanEqual')
        source += ' %bool ' + ('%next' if compare_update else '%x') + ' %bound\n'
        if bypass:
            source += '''%choose = OpIEqual %bool %x %zero
OpSelectionMerge %join None
OpBranchConditional %choose %guard %join
%guard = OpLabel
'''
        source += '''OpBranchConditional %quit %merge %continuation
%continuation = OpLabel
'''
        if bypass:
            source += 'OpBranch %join\n%join = OpLabel\n'
        source += '''OpBranch %latch
%latch = OpLabel
OpBranch %header
%merge = OpLabel
'''
    return source + 'OpReturn\nOpFunctionEnd\n'


def assemble(source):
    with tempfile.TemporaryDirectory() as folder:
        path = Path(folder) / 'shader.spvasm'
        path.write_text(source)
        binary = path.with_suffix('.spv')
        subprocess.run(['spirv-as', '--target-env', 'vulkan1.2', str(path), '-o', str(binary)], check=True)
        subprocess.run(['spirv-val', '--target-env', 'vulkan1.2', str(binary)], check=True)
        return binary.read_bytes()


class BoundedBankTests(ConstantBankTests):
    def check_fold(self, expression, expected):
        original = module(expression)
        output, proofs = fold_bounded_banks(original)
        if expected is None:
            self.assertEqual((output, proofs), (original, []))
        else:
            self.assertEqual([proof['bank'] for proof in proofs], [expected])
            self.assertNotEqual(output, original)

    def test_bitwise_and_loop_bounds(self):
        for loop in (False, True):
            with self.subTest(loop=loop):
                original = assemble(shader_source(loop))
                output, proofs = fold_bounded_banks(original)
                self.assertEqual([proof['bank'] for proof in proofs], [1])
                self.assertEqual(len(proofs[0]['loop_invariants']), int(loop))
                with tempfile.TemporaryDirectory() as folder:
                    path = Path(folder) / 'folded.spv'
                    path.write_bytes(output)
                    subprocess.run(['spirv-val', '--target-env', 'vulkan1.2', str(path)], check=True)

    def test_unproven_loop_rejected(self):
        for options in (dict(initial=13), dict(bound=0), dict(signed=True),
                        dict(compare_update=False), dict(bypass=True)):
            with self.subTest(options=options):
                original = assemble(shader_source(True, **options))
                self.assertEqual(fold_bounded_banks(original), (original, []))

    def test_large_valid_range_is_not_constant(self):
        for bound in (4097, 5000, 4294967295):
            original = assemble(shader_source(True, bound=bound))
            self.assertEqual(fold_bounded_banks(original), (original, []))

    def test_inductive_boundaries(self):
        for initial, bound in ((0, 1), (0, 4096), (12, 13), (4095, 4096)):
            original = assemble(shader_source(True, initial=initial, bound=bound))
            self.assertEqual([p['bank'] for p in fold_bounded_banks(original)[1]], [1])

    def test_non_read_only_dispatcher(self):
        original = assemble(shader_source())
        header, instructions = _instructions(original)
        for opcode, args in instructions:
            if opcode == 61:
                args.append(1)  # Volatile
                break
        changed = _pack(header, instructions)
        self.assertEqual(fold_bounded_banks(changed), (changed, []))

    def test_undefined_bit_operations_are_not_proved(self):
        for expression in ('%a = OpShiftRightLogical %u32 %x %thirtytwo\n%selector = OpBitwiseOr %u32 %a %one',
                           '%selector = OpBitFieldUExtract %u32 %x %thirtytwo %one'):
            self.check_fold(expression, None)

    def test_loop_incoming_values_cannot_be_swapped(self):
        original = assemble(shader_source(True))
        header, instructions = _instructions(original)
        for opcode, args in instructions:
            if opcode == 245:
                args[2], args[4] = args[4], args[2]
        changed = _pack(header, instructions)
        self.assertEqual(fold_bounded_banks(changed), (changed, []))


if __name__ == '__main__':
    unittest.main()
