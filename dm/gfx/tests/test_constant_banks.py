"""Safety checks for proving indirect constant-buffer bank expressions."""
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from dmsh_nx2_spirv import fold_constant_banks


def module(expression):
    source = '''OpCapability Shader
OpMemoryModel Logical GLSL450
OpEntryPoint Vertex %main "main" %vertex %position %c0 %c1 %c2
OpName %c0 "c0"
OpName %c1 "c1"
OpName %c2 "c2"
OpDecorate %vertex BuiltIn VertexIndex
OpDecorate %position BuiltIn Position
OpDecorate %array ArrayStride 16
OpDecorate %block Block
OpMemberDecorate %block 0 Offset 0
OpDecorate %c0 DescriptorSet 0
OpDecorate %c0 Binding 0
OpDecorate %c1 DescriptorSet 0
OpDecorate %c1 Binding 1
OpDecorate %c2 DescriptorSet 0
OpDecorate %c2 Binding 2
%void = OpTypeVoid
%u32 = OpTypeInt 32 0
%f32 = OpTypeFloat 32
%v4u = OpTypeVector %u32 4
%v4f = OpTypeVector %f32 4
%zero = OpConstant %u32 0
%one = OpConstant %u32 1
%two = OpConstant %u32 2
%sixteen = OpConstant %u32 16
%thirtytwo = OpConstant %u32 32
%max = OpConstant %u32 4294967295
%array = OpTypeArray %v4u %sixteen
%block = OpTypeStruct %array
%blockptr = OpTypePointer Uniform %block
%vecptr = OpTypePointer Uniform %v4u
%inputptr = OpTypePointer Input %u32
%outputptr = OpTypePointer Output %v4f
%c0 = OpVariable %blockptr Uniform
%c1 = OpVariable %blockptr Uniform
%c2 = OpVariable %blockptr Uniform
%vertex = OpVariable %inputptr Input
%position = OpVariable %outputptr Output
%loadtype = OpTypeFunction %v4u %u32 %u32
%maintype = OpTypeFunction %void
%load = OpFunction %v4u None %loadtype
%bank = OpFunctionParameter %u32
%offset = OpFunctionParameter %u32
%entry = OpLabel
OpSelectionMerge %merge None
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
%merge = OpLabel
OpUnreachable
OpFunctionEnd
%main = OpFunction %void None %maintype
%start = OpLabel
%x = OpLoad %u32 %vertex
''' + expression + '''
%value = OpFunctionCall %v4u %load %selector %zero
%asfloat = OpBitcast %v4f %value
OpStore %position %asfloat
OpReturn
OpFunctionEnd
'''
    with tempfile.TemporaryDirectory() as folder:
        assembly = Path(folder) / 'shader.spvasm'
        binary = assembly.with_suffix('.spv')
        assembly.write_text(source)
        subprocess.run(['spirv-as', '--target-env', 'vulkan1.2', str(assembly), '-o', str(binary)], check=True)
        subprocess.run(['spirv-val', '--target-env', 'vulkan1.2', str(binary)], check=True)
        return binary.read_bytes()


class ConstantBankTests(unittest.TestCase):
    def check_fold(self, expression, expected):
        original = module(expression)
        output, proofs = fold_constant_banks(original)
        if expected is None:
            self.assertEqual(output, original)
            self.assertEqual(proofs, [])
            return
        self.assertEqual([p['bank'] for p in proofs], [expected])
        self.assertTrue(all(p['result'] == 'unsat' for p in proofs))
        with tempfile.TemporaryDirectory() as folder:
            binary = Path(folder) / 'rewritten.spv'
            binary.write_bytes(output)
            subprocess.run(['spirv-val', '--target-env', 'vulkan1.2', str(binary)], check=True)

    def test_modular_arithmetic(self):
        cases = [
            ('%cancel = OpISub %u32 %x %x\n%selector = OpIAdd %u32 %cancel %one', 1),
            ('%a = OpIAdd %u32 %x %max\n%b = OpISub %u32 %x %one\n%c = OpISub %u32 %a %b\n%selector = OpIAdd %u32 %c %two', 2),
            ('%a = OpIMul %u32 %x %two\n%b = OpIAdd %u32 %x %x\n%c = OpISub %u32 %a %b\n%selector = OpIAdd %u32 %c %one', 1),
            ('%a = OpBitFieldUExtract %u32 %x %zero %sixteen\n%b = OpShiftLeftLogical %u32 %a %sixteen\n%selector = OpBitFieldUExtract %u32 %b %zero %sixteen', 0),
        ]
        for expression, expected in cases:
            with self.subTest(expression=expression):
                self.check_fold(expression, expected)

    def test_nonconstant_or_undefined(self):
        for expression in [
            '%selector = OpBitFieldUExtract %u32 %x %zero %two',
            '%selector = OpIAdd %u32 %x %one',
            '%selector = OpIMul %u32 %x %x',
            '%selector = OpShiftRightLogical %u32 %x %thirtytwo',
            '%selector = OpBitFieldUExtract %u32 %x %thirtytwo %one',
        ]:
            with self.subTest(expression=expression):
                self.check_fold(expression, None)

    def test_unknown_operation_is_unconstrained(self):
        self.check_fold('%a = OpBitwiseXor %u32 %x %one\n%selector = OpIAdd %u32 %a %one', None)
        self.check_fold('%a = OpBitwiseXor %u32 %x %one\n%b = OpISub %u32 %a %a\n%selector = OpIAdd %u32 %b %one', 1)

    def test_non_read_only_dispatcher(self):
        data = module('%cancel = OpISub %u32 %x %x\n%selector = OpIAdd %u32 %cancel %one')
        words = list(struct.unpack(f'<{len(data)//4}I', data))
        at = 5
        while at < len(words):
            size, opcode = words[at] >> 16, words[at] & 0xffff
            if opcode == 61:  # Add a Volatile operand; no longer the supported plain read.
                words[at] = ((size+1) << 16) | opcode
                words.insert(at+size, 1)
                break
            at += size
        changed = struct.pack(f'<{len(words)}I', *words)
        self.assertEqual(fold_constant_banks(changed), (changed, []))


if __name__ == '__main__':
    unittest.main()
