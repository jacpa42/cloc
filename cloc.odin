package cloc

import "base:runtime"
import "core:fmt"
import "core:math/bits"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:reflect"
import "core:testing"
import "core:thread"
import "core:time"

SKIP_HIDDEN := false
SKIP_DIRS := []string{".git", "target"}
MAX_FILE_SIZE :: 128 * mem.Kilobyte
PATH_BUF_SIZE :: mem.Megabyte
MIN_THREADS :: 1
MAX_THREADS :: 32
#assert(MAX_THREADS > MIN_THREADS)

Comment :: distinct [2]u8

@(rodata)
COMMENT_STR := [Code]Comment {
	.unknown = {},
	.c       = {'/', '/'},
	.cpp     = {'/', '/'},
	.h       = {'/', '/'},
	.json    = {},
	.lua     = {'-', '-'},
	.odin    = {'/', '/'},
	.py      = {'#', '\x00'},
	.rs      = {'/', '/'},
	.zig     = {'/', '/'},
}

@(rodata)
MULTILINE_COMMENT_BEGIN_STR := [Code]Comment {
	.unknown = {},
	.c       = {'/', '*'},
	.cpp     = {'/', '*'},
	.h       = {'/', '*'},
	.json    = {},
	.lua     = {},
	.odin    = {'/', '*'},
	.py      = {},
	.rs      = {'/', '*'},
	.zig     = {'/', '*'},
}

@(rodata)
MULTILINE_COMMENT_END_STR := [Code]Comment {
	.unknown = {},
	.c       = {'*', '/'},
	.cpp     = {'*', '/'},
	.h       = {'*', '/'},
	.json    = {},
	.lua     = {},
	.odin    = {'*', '/'},
	.py      = {},
	.rs      = {'*', '/'},
	.zig     = {'*', '/'},
}

Code :: enum u8 {
	unknown = 0,
	c,
	cpp,
	h,
	json,
	lua,
	odin,
	py,
	rs,
	zig,
}

Meta :: struct {
	tag:   Code,
	comnt: Comment,
	ml_st: Comment,
	ml_ed: Comment,
}
#assert(size_of(Meta) == 7)

CodeFile :: struct {
	meta:  Meta,
	info:  Info,
	stats: Stats,
}
#assert(size_of(CodeFile) == 8 + 12 + 12)

Info :: struct {
	path_start: u32,
	path_end:   u32,
	byte_size:  i32,
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

	pbuf = make([dynamic]u8, 0, mem.PAGE_SIZE); defer delete(pbuf)

	time.stopwatch_start(&subproc_timer)
	codefiles := make([dynamic]CodeFile, 0, 128); defer delete(codefiles)
	make_codefile_list(&codefiles, ".")
	time.stopwatch_stop(&subproc_timer)
	fmt.eprintfln("Found {} files in {}", len(codefiles), time.stopwatch_duration(subproc_timer))

	total_size_of_all_files: i64 = 0
	for cf in codefiles {total_size_of_all_files += i64(cf.info.byte_size)}

	// Process files
	time.stopwatch_reset(&subproc_timer); time.stopwatch_start(&subproc_timer)
	{
		num_eaters := clamp(i64(os.get_processor_core_count()), MIN_THREADS, MAX_THREADS)
		chunk_size := total_size_of_all_files / num_eaters

		threads: [dynamic; MAX_THREADS]^thread.Thread
		defer for t in threads[:] {thread.destroy(t)}

		index := 0
		defer eat_chunk(codefiles[index:]) // eat the rest of them
		for _ in 0 ..< num_eaters - 1 {
			start := index
			size_assigned: i64 = 0
			for index < len(codefiles) && size_assigned < chunk_size {
				size_assigned += i64(codefiles[index].info.byte_size)
				index += 1
			}
			chunk := codefiles[start:index]
			if len(chunk) > 0 {
				append(&threads, thread.create_and_start_with_poly_data(chunk, eat_chunk))
			}
			if size_assigned >= total_size_of_all_files {break}
		}

	}

	// Merge stats
	total_lines := 0
	combined_stats: [Code]Stats
	for codefile in codefiles[:] {
		codefile_stats_merge(&combined_stats[codefile.meta.tag], codefile.stats)
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
	if len(chunk) == 0 {return}

	file_data_buf := make([]u8, MAX_FILE_SIZE); defer delete(file_data_buf)
	file_data_arena: mem.Arena; mem.arena_init(&file_data_arena, file_data_buf)
	file_data_allocator := mem.arena_allocator(&file_data_arena)

	for &codefile in chunk {
		defer mem.arena_free_all(&file_data_arena)
		path := string(pbuf[codefile.info.path_start:codefile.info.path_end])
		data, err := os.read_entire_file_from_path(path, file_data_allocator)
		if err == nil {make_codefile_stats(&codefile.stats, codefile.meta, &data)}
	}
}

split_lines_iterator :: proc(s: ^[]u8) -> (line: []u8, ok: bool) {
	l := len(s)
	for index in 0 ..< l {
		if s[index] == '\n' {
			line, ok = s[:index], true
			s^ = s[index + 1:]
			return
		}
	}
	ok = len(s) > 0
	line = s^
	s^ = s[len(s):]
	return
}

@(test)
split_those_lines :: proc(t: ^testing.T) {
	lines := transmute([]u8)(string("hi\nmy\nname\nis\njacob\n"))
	line_array := []string{"hi", "my", "name", "is", "jacob", ""}
	index := 0
	for line in split_lines_iterator(&lines) {
		defer index += 1
		testing.expect(t, string(line) == line_array[index])
	}
}

starts_with :: proc(s: []u8, pat: Comment) -> bool {
	lpat := len_comment_prefix(pat)
	return(
		lpat > 0 &&
		len(s) >= int(lpat) &&
		(pat[0] == 0 || pat[0] == s[0]) &&
		(pat[1] == 0 || pat[1] == s[1]) \
	)
}

@(test)
stw :: proc(t: ^testing.T) {
	{ 	// nowhere
		comment_str: []Comment = {Comment{}, Comment{'-', '\x00'}, Comment{'/', '*'}}
		strings: [][]u8 = {
			transmute([]u8)string(""),
			transmute([]u8)string("**/"),
			transmute([]u8)string("**//slkjflsffoijosvsjfsjf**//"),
		}
		for cstr in comment_str {
			for st in strings {
				testing.expectf(
					t,
					!starts_with(st, cstr),
					"%s starts {} {}?",
					st,
					rune(cstr[0]),
					rune(cstr[1]),
				)
			}
		}

		cstr := Comment{'-', '-'}
		st := transmute([]u8)string("-")
		testing.expectf(
			t,
			!starts_with(st, cstr),
			"%s doesnt starts {} {}?",
			st,
			rune(cstr[0]),
			rune(cstr[1]),
		)
	}
	{ 	// somewhere
		cstr: Comment
		st: []u8

		cstr = Comment{'-', '-'}
		st = transmute([]u8)string("--327666alaallaa")
		testing.expectf(
			t,
			starts_with(st, cstr),
			"%s doesnt starts {} {}?",
			st,
			rune(cstr[0]),
			rune(cstr[1]),
		)

		cstr = Comment{'/', '-'}
		st = transmute([]u8)string("/-hleooo")
		testing.expectf(
			t,
			starts_with(st, cstr),
			"%s doesnt starts {} {}?",
			st,
			rune(cstr[0]),
			rune(cstr[1]),
		)

		cstr = Comment{'-', '?'}
		st = transmute([]u8)string("-?aooooo")
		testing.expectf(
			t,
			starts_with(st, cstr),
			"%s doesnt starts {} {}?",
			st,
			rune(cstr[0]),
			rune(cstr[1]),
		)
	}
}

ends_with :: proc(s: []u8, pat: Comment) -> bool {
	lpat := len_comment_prefix(pat)
	return(
		lpat > 0 &&
		len(s) >= int(lpat) &&
		(pat[0] == 0 || pat[0] == s[len(s) - 2]) &&
		(pat[1] == 0 || pat[1] == s[len(s) - 1]) \
	)
}

@(test)
etw :: proc(t: ^testing.T) {
	{ 	// nowhere
		comment_str: []Comment = {Comment{}, Comment{'-', '\x00'}, Comment{'/', '*'}}
		strings: [][]u8 = {
			transmute([]u8)string("   "),
			transmute([]u8)string("**/"),
			transmute([]u8)string("**//slkjflsffoijosvsjfsjf**//"),
		}
		for cstr in comment_str {
			for st in strings {
				testing.expectf(
					t,
					!ends_with(st, cstr),
					"%s ends with {} {} {} {}?",
					st,
					rune(cstr[0]),
					rune(cstr[1]),
					(cstr[0] == 0 || st[len(st) - 2] == cstr[0]),
					(cstr[1] == 0 || st[len(st) - 1] == cstr[1]),
				)
			}
		}

		cstr := Comment{'-', '-'}
		st := transmute([]u8)string("-")
		testing.expectf(
			t,
			!ends_with(st, cstr),
			"%s ends with {} {}?",
			st,
			rune(cstr[0]),
			rune(cstr[1]),
		)

		cstr = Comment{'\x00', '*'}
		st = transmute([]u8)string("------**********")
		testing.expectf(
			t,
			ends_with(st, cstr),
			"%s ends with {} {}?",
			st,
			rune(cstr[0]),
			rune(cstr[1]),
		)
	}
	{ 	// somewhere
		cstr: Comment
		st: []u8

		cstr = Comment{'-', '-'}
		st = transmute([]u8)string("--i277777c--")
		testing.expectf(
			t,
			ends_with(st, cstr),
			"%s doesnt end with {} {}?",
			st,
			rune(cstr[0]),
			rune(cstr[1]),
		)

		cstr = Comment{'/', '*'}
		st = transmute([]u8)string("//*")
		testing.expectf(
			t,
			ends_with(st, cstr),
			"%s doesnt end with {} {}?",
			st,
			rune(cstr[0]),
			rune(cstr[1]),
		)

		cstr = Comment{'-', '?'}
		st = transmute([]u8)string("?-333999977777777-?")
		testing.expectf(
			t,
			ends_with(st, cstr),
			"%s doesnt end with \"{}\"!=\"{}\"?",
			st,
			st[len(st) - 2:],
			cstr,
		)

		cstr = Comment{'*', '\x00'}
		st = transmute([]u8)string("------**********")
		testing.expectf(
			t,
			ends_with(st, cstr),
			"%s doesnt end with {} {}?",
			st,
			rune(cstr[0]),
			rune(cstr[1]),
		)
	}
}

trim_right :: proc(s: []u8) -> (trimmed: []u8) {
	trimmed = s
	for len(trimmed) > 0 {
		last := len(trimmed) - 1
		switch trimmed[last] {
		case '\t', '\n', '\v', '\f', '\r', ' ':
			trimmed = trimmed[:last]
		case:
			return
		}
	}
	return
}

trim_left :: proc(s: []u8) -> (trimmed: []u8) {
	trimmed = s
	for len(trimmed) > 0 {
		switch trimmed[0] {
		case '\t', '\n', '\v', '\f', '\r', ' ':
			trimmed = trimmed[1:]
		case:
			return
		}
	}
	return
}

trim :: proc(s: []u8) -> (trimmed: []u8) {
	return trim_left(trim_right(s))
}

len_comment_prefix :: proc(cp: Comment) -> u8 {
	return u8(cp[0] != 0) + u8(cp[1] != 0)
}

make_codefile_stats :: proc(stats: ^Stats, meta: Meta, data: ^[]u8) {
	stats.num_files += 1
	in_multiline_comment := false

	for str in split_lines_iterator(data) {
		line := trim(str)
		if len(line) == 0 {
			if in_multiline_comment {
				stats.comments += 1
			}
			continue
		}

		if in_multiline_comment {
			in_multiline_comment = !ends_with(line, meta.ml_ed)
			stats.comments += 1; continue
		} else if starts_with(line, meta.ml_st) {
			in_multiline_comment = true
			stats.comments += 1; continue
		}

		if starts_with(line, meta.comnt) {
			stats.comments += 1; continue
		}

		stats.code += 1; continue
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
	for skip_dir in SKIP_DIRS {
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
make_codefile_list :: proc(list: ^[dynamic]CodeFile, starting_directory: string) {
	if should_skip_dir(starting_directory) {
		// fmt.eprintln("Skipping {}", starting_directory)
		return
	}
	f, oerr := os.open(starting_directory)
	if oerr != nil {return}
	defer os.close(f)

	it := os.read_directory_iterator_create(f)
	defer os.read_directory_iterator_destroy(&it)

	for info in os.read_directory_iterator(&it) {
		make_codefile_list_from_finfo(list, info) or_continue
	}
}

make_codefile_list_from_finfo :: proc(list: ^[dynamic]CodeFile, info: os.File_Info) -> os.Error {
	#partial switch info.type {
	case .Regular:
		if should_skip_file(info.name) {return nil}

		tag := codefile_tag(info.fullpath)
		if tag == .unknown || info.size > MAX_FILE_SIZE {return nil}

		path_strt := len(pbuf)
		path_back := path_strt + len(info.fullpath)
		append(&pbuf, info.fullpath)

		comment_data := Meta {
			tag   = tag,
			comnt = COMMENT_STR[tag],
			ml_st = MULTILINE_COMMENT_BEGIN_STR[tag],
			ml_ed = MULTILINE_COMMENT_END_STR[tag],
		}

		assert(info.size >= bits.I32_MIN); assert(info.size <= bits.I32_MAX)
		assert(path_strt >= bits.U32_MIN); assert(path_strt <= bits.U32_MAX)
		assert(path_back >= bits.U32_MIN); assert(path_back <= bits.U32_MAX)
		codefile_info := Info {
			path_start = u32(path_strt),
			path_end   = u32(path_back),
			byte_size  = i32(info.size),
		}
		append(list, CodeFile{comment_data, codefile_info, Stats{}})

	case .Directory:
		make_codefile_list(list, info.fullpath)

	}

	return nil
}

