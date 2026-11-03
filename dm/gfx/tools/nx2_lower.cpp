// Check NX2 instruction lowering against PokeDinner.
// Build: clang++ -std=c++20 -O2 -I <pokedinner>/src nx2_lower.cpp -lsqlite3 -lz -o nx2_lower
// Usage: nx2_lower database report.tsv [sample-output-directory]
#include <sqlite3.h>
#include <zlib.h>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include "shader_recompiler/frontend/ampere/lower_to_maxwell.h"

static uint32_t u32at(const std::vector<uint8_t>& b, size_t offset) {
    if (offset + 4 > b.size()) throw std::runtime_error("truncated object");
    uint32_t value;
    std::memcpy(&value, b.data() + offset, 4);
    return value;
}

int main(int argc, char** argv) {
    if (argc < 3 || argc > 4) return 2;
    sqlite3* database{};
    if (sqlite3_open_v2(argv[1], &database, SQLITE_OPEN_READONLY, nullptr) != SQLITE_OK) return 2;
    sqlite3_stmt* statement{};
    if (sqlite3_prepare_v2(database, "SELECT sha256,glslc_zlib FROM shaders", -1, &statement, nullptr) != SQLITE_OK) return 2;
    std::ofstream report(argv[2]);
    if (!report) return 2;
    report << "sha256\tstage\tstatus\terror_offset\topcode\tsource_bytes\tmaxwell_words\ttexture_buffer\terror\n";
    if (argc == 4) std::filesystem::create_directories(argv[3]);
    size_t count{}, passed{};
    std::map<unsigned, unsigned> samples;
    const char* stages[] = {"vs", "ps", "gs", "hs", "ds", "cs"};
    while (sqlite3_step(statement) == SQLITE_ROW) {
        const std::string key{reinterpret_cast<const char*>(sqlite3_column_text(statement, 0))};
        const auto* compressed = static_cast<const uint8_t*>(sqlite3_column_blob(statement, 1));
        const auto compressed_size = sqlite3_column_bytes(statement, 1);
        std::vector<uint8_t> blob(65536);
        int status;
        for (;;) {
            uLongf size = blob.size();
            status = uncompress(blob.data(), &size, compressed, compressed_size);
            if (status == Z_OK) { blob.resize(size); break; }
            if (status != Z_BUF_ERROR || blob.size() >= 16 * 1024 * 1024) throw std::runtime_error("invalid compressed object");
            blob.resize(blob.size() * 2);
        }
        const auto control = u32at(blob, 0x60);
        const auto control_size = u32at(blob, control + 0x30);
        const auto code_size = u32at(blob, control + 0x38);
        const auto stage = u32at(blob, control + 0x54) >> 16;
        if (stage >= 6) throw std::runtime_error("invalid stage");
        const auto header_size = stage == 5 ? 0U : 128U;
        const auto code = control + control_size;
        if (code_size < header_size || code + code_size > blob.size() || (code_size - header_size) % 16)
            throw std::runtime_error("invalid instruction bounds");
        std::vector<Shader::Ampere::Instruction> native((code_size - header_size) / 16);
        std::memcpy(native.data(), blob.data() + code + header_size, native.size() * 16);
        const auto result = Shader::Ampere::LowerToMaxwell(native, "full");
        const unsigned opcode = result.error_offset / 16 < native.size() ? native[result.error_offset / 16].Bits(0, 12) : 0;
        report << key << '\t' << stages[stage] << '\t' << (result ? "ok" : "error") << '\t'
               << result.error_offset << '\t' << opcode << '\t' << result.source_size << '\t'
               << result.instructions.size() << '\t' << result.required_texture_buffer << '\t' << result.error << '\n';
        ++count;
        if (result) {
            ++passed;
            if (argc == 4 && samples[stage]++ < 12) {
                std::vector<uint64_t> maxwell(10);
                if (stage != 5) std::memcpy(maxwell.data(), blob.data() + code, 80);
                for (uint64_t instruction : result.instructions) {
                    if (maxwell.size() % 4 == 0) maxwell.push_back(0);
                    maxwell.push_back(instruction);
                }
                maxwell.push_back(0);
                std::ofstream file(std::filesystem::path(argv[3]) / (key + "." + stages[stage] + ".bin"), std::ios::binary);
                file.write(reinterpret_cast<const char*>(maxwell.data()), maxwell.size() * 8);
            }
        }
        if (count % 10000 == 0) std::cerr << count << " processed, " << passed << " lowered\n";
    }
    sqlite3_finalize(statement);
    sqlite3_close(database);
    std::cout << count << " shaders, " << passed << " lowered, " << count - passed << " rejected\n";
    return 0;
}
