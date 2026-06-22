package cloc

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:reflect"
import "core:strings"
import "core:thread"
import "core:time"

FOLLOW_SYMLINKS := true
SKIP_HIDDEN := false
SKIP_PATTERNS := []string{".git", "target"}
MAX_FILE_SIZE := i64(mem.Megabyte)
PATH_BUF_SIZE :: mem.Megabyte
WHITESPACE :: " /n/t"

@(rodata)
COMMENT_STR := #partial [Code]string {
	.odin = "//",
	.lua  = "--",
	.py   = "#",
	.rs   = "//",
	.c    = "//",
	.zig  = "//",
}

@(rodata)
MULTILINE_COMMENT_BEGIN_STR := #partial [Code]string {
	.odin = "/*",
	.rs   = "/*",
	.c    = "/*",
	.zig  = "/*",
}

@(rodata)
MULTILINE_COMMENT_END_STR := #partial [Code]string {
	.odin = "*/",
	.rs   = "*/",
	.c    = "*/",
	.zig  = "*/",
}

Void :: struct {}

Code :: enum {
	unknown = 0,
	odin,
	lua,
	py,
	rs,
	zig,
	json,
	c,
}

CodeFile :: struct {
	tag:        Code,
	path_start: int,
	path_end:   int,
	byte_size:  i64,

	// Computed
	stats:      Stats,
}

Stats :: struct {
	num_files: u32,
	code:      u32,
	comments:  u32,
}

pbuf: [dynamic]u8

main :: proc() {
	proc_timer: time.Stopwatch
	time.stopwatch_start(&proc_timer)
	defer fmt.eprintln("Finished in", time.stopwatch_duration(proc_timer))

	subproc_timer: time.Stopwatch

	pbuf = make([dynamic]u8); defer delete(pbuf)

	time.stopwatch_start(&subproc_timer)
	directories_seen := make(map[string]Void)
	codefiles := make([dynamic]CodeFile, 0, 128); defer delete(codefiles)
	make_codefile_list(&codefiles, ".", &directories_seen)
	time.stopwatch_stop(&subproc_timer)
	fmt.eprintfln("Found {} files in {}", len(codefiles), time.stopwatch_duration(subproc_timer))

	total_size_of_all_files: i64 = 0
	for cf in codefiles {total_size_of_all_files += cf.byte_size}

	// Process files
	time.stopwatch_reset(&subproc_timer); time.stopwatch_start(&subproc_timer)
	{
		NUM_PROCESSES :: 24
		chunk_size := total_size_of_all_files / NUM_PROCESSES

		threads: [NUM_PROCESSES]^thread.Thread
		index := 0
		when NUM_PROCESSES > 1 {
			for n in 0 ..< NUM_PROCESSES - 1 {
				start := index
				size_assigned: i64 = 0
				for index < len(codefiles) && size_assigned < chunk_size {
					size_assigned += codefiles[index].byte_size
					index += 1
				}
				chunk := codefiles[start:index]
				threads[n] = thread.create_and_start_with_poly_data(chunk, eat_chunk)
			}
		}
		chunk := codefiles[index:]
		threads[NUM_PROCESSES - 1] = thread.create_and_start_with_poly_data(chunk, eat_chunk)

		for t in threads {thread.destroy(t)}
	}

	// Merge stats
	total_lines := 0
	combined_stats: [Code]Stats
	for codefile in codefiles[:] {
		codefile_stats_merge(&combined_stats[codefile.tag], codefile.stats)
		total_lines += int(codefile.stats.code + codefile.stats.comments)
	}
	time.stopwatch_stop(&subproc_timer)

	fmt.eprintfln(
		"Processed {} loc {} files in {}",
		total_lines,
		len(codefiles),
		time.stopwatch_duration(subproc_timer),
	)

	for tag in Code {
		if tag != .unknown && combined_stats[tag].num_files > 0 {
			fmt.eprintfln("{}: %#v", tag, combined_stats[tag])
		}
	}
}

eat_chunk :: proc(chunk: []CodeFile) {
	file_data_buf := make([]u8, MAX_FILE_SIZE); defer delete(file_data_buf)
	file_data_arena: mem.Arena; mem.arena_init(&file_data_arena, file_data_buf)
	file_data_allocator := mem.arena_allocator(&file_data_arena)

	for &codefile in chunk {
		defer mem.arena_free_all(&file_data_arena)
		path := string(pbuf[codefile.path_start:codefile.path_end])
		data, err := os.read_entire_file_from_path(path, file_data_allocator)
		if err == nil {make_codefile_stats(&codefile.stats, codefile.tag, data)}
	}
}

make_codefile_stats :: proc(stats: ^Stats, tag: Code, data: []byte) {
	stats.num_files += 1
	datastr := string(data)
	check_comments := len(COMMENT_STR[tag]) > 0
	for str in strings.split_lines_iterator(&datastr) {
		line := strings.trim_left(str, WHITESPACE)
		if check_comments && strings.starts_with(line, COMMENT_STR[tag]) {
			stats.comments += 1
		} else { 	// TODO: Multiline comments
			stats.code += 1
		}
	}
}

codefile_stats_merge :: proc(dst: ^Stats, src: Stats) {
	dst.num_files += src.num_files
	dst.comments += src.comments
	dst.code += src.code
}

codefile_tag :: proc(full_path: string) -> Code {
	code := Code.unknown

	ext := filepath.ext(full_path); if len(ext) > 0 && ext[0] == '.' {
		code, _ = reflect.enum_from_name(Code, ext[1:])
	}

	return code
}

should_skip_dir :: proc(dir: string) -> bool {
	dir_name := filepath.base(dir)
	if SKIP_HIDDEN && len(dir_name) > 1 && dir_name[0] == '.' { 	// hidden
		return true}
	for skip_dir in SKIP_PATTERNS {
		if skip_dir == dir_name {
			return true
		}
	}
	return false
}

should_skip_file :: proc(file_name: string) -> bool {
	return SKIP_HIDDEN && len(file_name) > 1 && file_name[0] == '.'
}

// Grows list with the context.allocator
make_codefile_list :: proc(
	list: ^[dynamic]CodeFile,
	starting_directory: string,
	directories_seen: ^map[string]Void,
) {
	if starting_directory in directories_seen || should_skip_dir(starting_directory) {
		// fmt.eprintln("Skipping {}", starting_directory)
		return
	} else {
		// fmt.eprintln("Recursing into directory {}", starting_directory)
		directories_seen[starting_directory] = {}
	}
	f, oerr := os.open(starting_directory)
	if oerr != nil {return}
	defer os.close(f)

	it := os.read_directory_iterator_create(f)
	defer os.read_directory_iterator_destroy(&it)

	for info in os.read_directory_iterator(&it) {
		make_codefile_list_from_finfo(list, info, directories_seen) or_continue
	}
}

make_codefile_list_from_finfo :: proc(
	list: ^[dynamic]CodeFile,
	info: os.File_Info,
	directories_seen: ^map[string]Void,
) -> os.Error {
	#partial switch info.type {
	case .Regular:
		if should_skip_file(info.name) {return nil}

		tag := codefile_tag(info.fullpath)
		if tag == .unknown || info.size > MAX_FILE_SIZE {return nil}

		path_start := len(pbuf)
		path_end := path_start + len(info.fullpath)
		append(&pbuf, info.fullpath)

		append(list, CodeFile{tag, path_start, path_end, info.size, Stats{}})

	case .Directory:
		make_codefile_list(list, info.fullpath, directories_seen)

	case .Symlink:
		if FOLLOW_SYMLINKS {
			location := os.read_link(info.fullpath, context.temp_allocator) or_return
			link_info := os.stat(location, context.temp_allocator) or_return
			return make_codefile_list_from_finfo(list, link_info, directories_seen)
		}
	}

	return nil
}

