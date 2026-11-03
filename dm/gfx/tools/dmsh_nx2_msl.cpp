// SPIRV-Cross entry point for native tessellation stage variants.
#include <spirv_cross/spirv_msl.hpp>
#include <fstream>
#include <iostream>
#include <vector>

int main(int argc, char** argv) {
    try {
        if (argc < 2 || argc > 3) throw std::runtime_error("usage: nx2-msl input.spv [control-points|--index-u32]");
        std::ifstream file(argv[1], std::ios::binary | std::ios::ate);
        if (!file) throw std::runtime_error("cannot open SPIR-V input");
        const auto size = file.tellg();
        if (size < 20 || size % 4) throw std::runtime_error("invalid SPIR-V size");
        std::vector<uint32_t> words(static_cast<size_t>(size) / 4);
        file.seekg(0);
        if (!file.read(reinterpret_cast<char*>(words.data()), size))
            throw std::runtime_error("truncated SPIR-V input");
        spirv_cross::CompilerMSL compiler(std::move(words));
        const auto stage = compiler.get_execution_model();
        if (stage != spv::ExecutionModelVertex && stage != spv::ExecutionModelTessellationControl &&
            stage != spv::ExecutionModelTessellationEvaluation)
            throw std::runtime_error("not a tessellation pipeline stage");
        if (stage == spv::ExecutionModelTessellationEvaluation) {
            if (argc != 3) throw std::runtime_error("domain stage requires the hull output control-point count");
            size_t consumed = 0;
            const auto count = std::stoul(argv[2], &consumed);
            if (argv[2][consumed] || count < 1 || count > 32)
                throw std::runtime_error("invalid hull output control-point count");
            compiler.set_execution_mode(spv::ExecutionModeOutputVertices, static_cast<uint32_t>(count));
        } else if (stage == spv::ExecutionModelVertex && argc == 3 && std::string(argv[2]) == "--index-u32") {
            // All source index widths are widened before the vertex-capture dispatch.
        } else if (argc != 2) {
            throw std::runtime_error("control-point argument is only valid for a domain stage");
        }
        const auto resources = compiler.get_shader_resources();
        for (const bool output : {false, true}) {
            for (const auto& variable : output ? resources.stage_outputs : resources.stage_inputs) {
                if (!compiler.has_decoration(variable.id, spv::DecorationPatch) ||
                    !compiler.has_decoration(variable.id, spv::DecorationLocation)) continue;
                const auto location = compiler.get_decoration(variable.id, spv::DecorationLocation);
                if (location >= 32) throw std::runtime_error("patch location outside native layout");
                compiler.set_name(variable.id, std::string(output ? "out_patch" : "in_patch") +
                                               std::to_string(location));
            }
        }
        auto options = compiler.get_msl_options();
        options.msl_version = 20300;
        options.argument_buffers = true;
        options.texture_buffer_native = true;
        options.pad_fragment_output_components = true;
        options.multi_patch_workgroup = true;
        options.raw_buffer_tese_input = true;
        options.vertex_for_tessellation = stage == spv::ExecutionModelVertex;
        if (stage == spv::ExecutionModelVertex && argc == 3)
            options.vertex_index_type = spirv_cross::CompilerMSL::Options::IndexType::UInt32;
        compiler.set_msl_options(options);
        std::cout << compiler.compile();
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
