// Extracts zip archives (.love games, .vsix extensions, GitHub downloads) using the central
// directory at the end of the file, which has every entry's real sizes. Walking the local
// headers instead fails on archives written as a stream (as VS Code extension packagers do):
// their local headers say 0 bytes and the sizes follow the data. Handles stored and deflated
// entries and ZIP64, streams each entry to disk, and refuses entries that would land outside
// the target folder.

#include "ZipExtract.h"

#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <zlib.h>

#ifdef _WIN32
#include <direct.h>
#define make_dir(path) _mkdir(path)
#define seek_to(fp, offset) _fseeki64(fp, (long long)(offset), SEEK_SET)
#define seek_end(fp) _fseeki64(fp, 0, SEEK_END)
#define tell(fp) _ftelli64(fp)
#else
#define make_dir(path) mkdir(path, 0755)
#define seek_to(fp, offset) fseeko(fp, (off_t)(offset), SEEK_SET)
#define seek_end(fp) fseeko(fp, 0, SEEK_END)
#define tell(fp) ftello(fp)
#endif

enum { kChunk = 1 << 16 };

static int fail(char *error, size_t size, const char *format, ...) {
    if (error && size) {
        va_list list;
        va_start(list, format);
        vsnprintf(error, size, format, list);
        va_end(list);
    }
    return 1;
}

static uint16_t u16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t u32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static uint64_t u64(const uint8_t *p) { return (uint64_t)u32(p) | (uint64_t)u32(p + 4) << 32; }

static int read_at(FILE *fp, uint64_t offset, void *buffer, size_t length) {
    return seek_to(fp, offset) == 0 && fread(buffer, 1, length, fp) == length;
}

/// mkdir -p for the folders in `path` (the last component too when `include_last`).
static void make_dirs(char *path, int include_last) {
    for (char *p = path + 1; *p; p++) {
        if (*p == '/') {
            *p = 0;
            make_dir(path);
            *p = '/';
        }
    }
    if (include_last) make_dir(path);
}

/// Whether an entry's name stays inside the target folder: relative, without "..".
static int safe_name(const char *name) {
    if (!*name || name[0] == '/') return 0;
    const char *part = name;
    while (*part) {
        const char *end = strchr(part, '/');
        size_t length = end ? (size_t)(end - part) : strlen(part);
        if (length == 2 && part[0] == '.' && part[1] == '.') return 0;
        if (!end) break;
        part = end + 1;
    }
    return 1;
}

/// Copies or inflates `compressed` bytes at the reader's position into `out`.
static int write_entry(FILE *in, FILE *out, int method, uint64_t compressed, uint64_t uncompressed, char *error, size_t size) {
    uint8_t *input = malloc(kChunk);
    uint8_t *output = malloc(kChunk);
    if (!input || !output) {
        free(input);
        free(output);
        return fail(error, size, "Out of memory.");
    }
    int result = 0;
    if (method == 0) {
        while (compressed > 0) {
            size_t n = compressed < kChunk ? (size_t)compressed : kChunk;
            if (fread(input, 1, n, in) != n || fwrite(input, 1, n, out) != n) { result = fail(error, size, "The archive is cut short."); break; }
            compressed -= n;
        }
    } else {
        z_stream stream;
        memset(&stream, 0, sizeof(stream));
        if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) {
            free(input);
            free(output);
            return fail(error, size, "Couldn't start decompressing.");
        }
        int status = Z_OK;
        uint64_t written = 0;
        while (status != Z_STREAM_END) {
            if (stream.avail_in == 0) {
                if (compressed == 0) break;
                size_t n = compressed < kChunk ? (size_t)compressed : kChunk;
                if (fread(input, 1, n, in) != n) break;
                compressed -= n;
                stream.next_in = input;
                stream.avail_in = (uInt)n;
            }
            stream.next_out = output;
            stream.avail_out = kChunk;
            status = inflate(&stream, Z_NO_FLUSH);
            if (status != Z_OK && status != Z_STREAM_END) break;
            size_t produced = kChunk - stream.avail_out;
            if (fwrite(output, 1, produced, out) != produced) { status = Z_ERRNO; break; }
            written += produced;
        }
        inflateEnd(&stream);
        if (status != Z_STREAM_END || written != uncompressed) result = fail(error, size, "Part of the archive is damaged.");
    }
    free(input);
    free(output);
    return result;
}

int dc_zip_extract(const char *zip_path, const char *target_dir, char *error, size_t error_size) {
    if (!zip_path || !target_dir) return fail(error, error_size, "No archive given.");
    FILE *fp = fopen(zip_path, "rb");
    if (!fp) return fail(error, error_size, "The archive couldn't be opened (%s).", strerror(errno));

    // The end of central directory record: within the last 64 KB + 22 bytes (it may end with a comment).
    seek_end(fp);
    uint64_t file_size = (uint64_t)tell(fp);
    size_t tail_size = file_size < 65557 ? (size_t)file_size : 65557;
    uint8_t *tail = malloc(tail_size ? tail_size : 1);
    if (!tail || !read_at(fp, file_size - tail_size, tail, tail_size)) {
        free(tail);
        fclose(fp);
        return fail(error, error_size, "The archive couldn't be read.");
    }
    long eocd = -1;
    for (long i = (long)tail_size - 22; i >= 0; i--) {
        if (u32(tail + i) == 0x06054b50) { eocd = i; break; }
    }
    if (eocd < 0) {
        free(tail);
        fclose(fp);
        return fail(error, error_size, "It isn't a zip archive.");
    }
    uint64_t count = u16(tail + eocd + 10);
    uint64_t directory_size = u32(tail + eocd + 12);
    uint64_t directory_offset = u32(tail + eocd + 16);
    uint64_t eocd_position = file_size - tail_size + (uint64_t)eocd;
    free(tail);

    // ZIP64: the real values are in the ZIP64 end record, found through its locator.
    if (count == 0xffff || directory_size == 0xffffffff || directory_offset == 0xffffffff) {
        uint8_t locator[20], record[56];
        if (eocd_position < 20 || !read_at(fp, eocd_position - 20, locator, 20) || u32(locator) != 0x07064b50 ||
            !read_at(fp, u64(locator + 8), record, 56) || u32(record) != 0x06064b50) {
            fclose(fp);
            return fail(error, error_size, "The archive's ZIP64 directory is damaged.");
        }
        count = u64(record + 32);
        directory_size = u64(record + 40);
        directory_offset = u64(record + 48);
    }
    if (directory_offset + directory_size > file_size || directory_size > (1u << 30)) {
        fclose(fp);
        return fail(error, error_size, "The archive's directory is damaged.");
    }
    uint8_t *directory = malloc(directory_size ? (size_t)directory_size : 1);
    if (!directory || !read_at(fp, directory_offset, directory, (size_t)directory_size)) {
        free(directory);
        fclose(fp);
        return fail(error, error_size, "The archive's directory couldn't be read.");
    }

    size_t target_length = strlen(target_dir);
    char *path = malloc(target_length + 70000);
    memcpy(path, target_dir, target_length + 1);
    make_dirs(path, 1);

    int result = 0;
    size_t at = 0;
    for (uint64_t index = 0; index < count && result == 0; index++) {
        const uint8_t *entry = directory + at;
        if (at + 46 > directory_size || u32(entry) != 0x02014b50) { result = fail(error, error_size, "The archive's directory is damaged."); break; }
        uint16_t flags = u16(entry + 8);
        uint16_t method = u16(entry + 10);
        uint64_t compressed = u32(entry + 20);
        uint64_t uncompressed = u32(entry + 24);
        uint16_t name_length = u16(entry + 28);
        uint16_t extra_length = u16(entry + 30);
        uint16_t comment_length = u16(entry + 32);
        uint64_t local = u32(entry + 42);
        if (at + 46 + name_length + extra_length + comment_length > directory_size) { result = fail(error, error_size, "The archive's directory is damaged."); break; }

        // ZIP64 extra field: 64-bit values for the fields that are 0xffffffff, in this order.
        const uint8_t *extra = entry + 46 + name_length;
        for (size_t e = 0; e + 4 <= extra_length;) {
            uint16_t id = u16(extra + e), length = u16(extra + e + 2);
            if (id == 0x0001) {
                const uint8_t *value = extra + e + 4;
                const uint8_t *end = value + length;
                if (uncompressed == 0xffffffff && value + 8 <= end) { uncompressed = u64(value); value += 8; }
                if (compressed == 0xffffffff && value + 8 <= end) { compressed = u64(value); value += 8; }
                if (local == 0xffffffff && value + 8 <= end) { local = u64(value); }
            }
            e += 4u + length;
        }

        char name[65536];
        memcpy(name, entry + 46, name_length);
        name[name_length] = 0;
        for (char *c = name; *c; c++) if (*c == '\\') *c = '/';
        at += 46u + name_length + extra_length + comment_length;

        if (!safe_name(name)) continue;   // a path outside the folder: never written
        if (flags & 1) { result = fail(error, error_size, "%s is encrypted.", name); break; }

        snprintf(path + target_length, 70000, "/%s", name);
        if (name[name_length - 1] == '/') {
            make_dirs(path, 1);
            continue;
        }
        if (method != 0 && method != 8) { result = fail(error, error_size, "%s uses a compression DuoCode can't read.", name); break; }

        uint8_t header[30];
        if (!read_at(fp, local, header, 30) || u32(header) != 0x04034b50) { result = fail(error, error_size, "%s is damaged.", name); break; }
        if (seek_to(fp, local + 30 + u16(header + 26) + u16(header + 28)) != 0) { result = fail(error, error_size, "%s is damaged.", name); break; }

        make_dirs(path, 0);
        FILE *out = fopen(path, "wb");
        if (!out) { result = fail(error, error_size, "%s couldn't be written (%s).", name, strerror(errno)); break; }
        result = write_entry(fp, out, method, compressed, uncompressed, error, error_size);
        if (fclose(out) != 0 && result == 0) result = fail(error, error_size, "%s couldn't be written.", name);
    }

    free(path);
    free(directory);
    fclose(fp);
    return result;
}
