# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Load guard: skip re-definition if already sourced (see tui.sh).
if test -n "${_tuish_md_loaded:-}"; then return 0; fi
_tuish_md_loaded=1
# src/md.sh - Markdown reader
# Standalone module. Depends on NOTHING — not compat.sh, not ord.sh, not str.sh.
# hl.sh is OPTIONAL: without it, fenced code degrades to flat default-styled lines.
#
# Provides:
#   tuish_md_emit STYLE PAYLOAD - the SINK. Override it; the default prints a record.
#   tuish_md_begin [MODE]       - reset the parser. MODE is 'post' (default) or 'section'.
#   tuish_md_feed LINE          - feed one source line
#   tuish_md_end                - flush the open block
#   tuish_md_file FILE [MODE]   - begin + read the file + end
#   tuish_md_meta KEY           - front-matter value -> TUISH_MD_META
#
# WHY A SINK AND NOT STDOUT. A reader has to keep the parse loop in its own shell,
# so a parser that printed records would force every consumer into a pipeline — and
# a pipeline is a subshell. Overriding one function is the trick tui.sh already uses
# for its IO stubs, and it lets a build script stream HTML while a reader fills a
# line buffer, from one parser, with no branching inside it.
#
# THE RECORD STREAM: "STYLE<TAB>PAYLOAD", one per line.
#
#   f       front matter          key<US>value
#   t       page title            plain text
#   h2..h5  heading               plain text (the number is the HTML level)
#   i       byline                plain text
#   p       paragraph             segments
#   b       bullet item           segments
#   n       ordered item          segments (the renderer supplies the number)
#   qb      blockquote opens      empty
#   q       blockquote paragraph  segments
#   cb      code block opens      the fence info string (may be empty)
#   c       code line             segments (from hl.sh)
#   g       image                 alt<US>src
#   d       caption               plain text
#   r       thematic break        empty
#   e       navigable entry       base<US>title<US>date
#
# Segments are "style<US>text" fields joined by US:
#
#   x plain · s strong · e emphasis · m inline code · k link text · u link URL
#
# BLOCK AND INLINE STYLES ARE SEPARATE NAMESPACES. The block style is the field
# before the TAB; inline styles live inside the payload. So block 'e' (entry) and
# inline 'e' (emphasis) never meet. It reads like a collision and is not one.
#
# A LINK RUNS FROM ITS 'k' SEGMENT TO THE NEXT 'u'. Everything between belongs
# inside the anchor, which is how [use `printf` instead](url) keeps its inline code.
# The URL is carried RAW: HTML makes it an href, a terminal paints a dim " (url)".
# Presentation belongs to the renderer, not the parser — that is what lets one
# parse feed both.

_TUISH_MD_US=$(printf '\037')
_TUISH_MD_TAB=$(printf '\011')
_TUISH_MD_CR=$(printf '\015')

# A backtick cannot be written as a backslash-escaped literal inside ${…}: mksh
# reads the escape as an unterminated command substitution and dies parsing the
# whole file. Held in a variable and always expanded QUOTED, which every shell
# treats as literal text — the same idiom hl.sh uses for its run strips. Note this
# is not the "pattern in a variable" trap: that one is about PATTERNS, and a quoted
# expansion is by definition not one.
_TUISH_MD_BT='`'

TUISH_MD_META=''
TUISH_MD_KEYS=''

# Infer navigable entries from list items linking to a local document.
#
# OFF BY DEFAULT, AND THAT MATTERS. A reader's Tab key cycles entries OR code
# blocks, never both — so one accidental entry inside a post silently disables
# code-block focus for that whole page, and posts on a blog cross-link each other
# constantly. Turn this on for index and list pages only.
TUISH_MD_ENTRIES=0

# Emit an 'i' byline from the 'author' and 'date' front matter, right after the
# title. Off by default: it is the one blog-shaped convention in this module.
TUISH_MD_BYLINE=0

_tuish_md_mode=post     # post: the first '#' is the title. section: every '#' is a heading.
_tuish_md_acc=''        # text of the block being accumulated
_tuish_md_pend=''       # its style ('' when no block is open)
_tuish_md_code=0        # inside a fenced code block
_tuish_md_fm=0          # inside the front-matter block
_tuish_md_inq=0         # inside a blockquote block
_tuish_md_com=0         # inside an HTML comment
_tuish_md_body=0        # a content line has been seen (front matter is closed)
_tuish_md_seen_t=0      # the title has been emitted
_tuish_md_last=''       # style of the last block emitted (the caption rule needs it)
_tuish_md_pay=''        # segment accumulator
_tuish_md_psty=''       # style of the last segment (for merging)
_tuish_md_text=''       # _tuish_md_plain's result
_tuish_md_span=''       # _tuish_md_close's results
_tuish_md_rest=''

_TUISH_MD_IDENT='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_'

# tuish_md_emit STYLE PAYLOAD — the sink. Override this.
tuish_md_emit ()
{
	printf '%s%s%s\n' "$1" "$_TUISH_MD_TAB" "$2"
}

# tuish_md_begin [MODE]
# MODE=post (default): the first '#' is the page title, emitted as 't'.
# MODE=section: every '#' is a section heading — an index page has no single title.
tuish_md_begin ()
{
	local _mdb_k _mdb_r
	_tuish_md_mode="${1:-post}"
	_tuish_md_acc='' _tuish_md_pend='' _tuish_md_code=0 _tuish_md_fm=0 _tuish_md_inq=0
	_tuish_md_com=0 _tuish_md_body=0 _tuish_md_seen_t=0 _tuish_md_last=''

	# Clear the front matter of the PREVIOUS document. The values live in
	# eval-created globals, so without this a key the next document does not define
	# still answers with the last one's value — a program parsing a run of files
	# would quietly stamp one document's author and date onto another.
	#
	# Split by parameter expansion rather than `for k in $TUISH_MD_KEYS`: a caller
	# is free to have set IFS to something that does not include a space, and a
	# build script iterating filenames very often has.
	_mdb_r="$TUISH_MD_KEYS"
	while test -n "$_mdb_r"
	do
		_mdb_r="${_mdb_r# }"
		case $_mdb_r in
			'') break ;;
			*' '*) _mdb_k="${_mdb_r%% *}"; _mdb_r="${_mdb_r#* }" ;;
			*)     _mdb_k="$_mdb_r"; _mdb_r='' ;;
		esac
		if test -n "$_mdb_k"; then eval "_tuish_md_m_$_mdb_k=''"; fi
	done

	TUISH_MD_KEYS='' TUISH_MD_META=''
	return 0
}

# _tuish_md_seg STYLE TEXT — append one inline segment, merging repeats.
# Empty text is dropped; whitespace-only text is kept.
_tuish_md_seg ()
{
	if test -z "$2"; then return 0; fi
	if test "$1" = "$_tuish_md_psty"
	then
		_tuish_md_pay="${_tuish_md_pay}$2"
		return 0
	fi
	if test -n "$_tuish_md_pay"
	then _tuish_md_pay="${_tuish_md_pay}${_TUISH_MD_US}$1${_TUISH_MD_US}$2"
	else _tuish_md_pay="$1${_TUISH_MD_US}$2"
	fi
	_tuish_md_psty="$1"
	return 0
}

# _tuish_md_close DELIM REST GATED
#   _tuish_md_span -> the text before the closing delimiter
#   _tuish_md_rest -> what follows it
# GATED=1 also requires the closer to be followed by end-of-string or a
# non-identifier byte. That is what stops snake_case_names from becoming italics —
# without it, '_' emphasis would mangle half the prose on a shell blog.
# Returns 1 when no valid closer exists. Call it in an `if`: under `set -e` a bare
# call would abort the caller on the unterminated case.
_tuish_md_close ()
{
	local _mdc_d="$1" _mdc_r="$2" _mdc_g="$3" _mdc_acc='' _mdc_pre _mdc_nx
	while :
	do
		case $_mdc_r in
			*"$_mdc_d"*) : ;;
			*) return 1 ;;
		esac
		_mdc_pre="${_mdc_r%%"$_mdc_d"*}"
		_mdc_r="${_mdc_r#*"$_mdc_d"}"
		if test "$_mdc_g" -eq 1
		then
			_mdc_nx="${_mdc_r%"${_mdc_r#?}"}"
			case $_mdc_nx in
				''|[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_]) : ;;
				*) _mdc_acc="${_mdc_acc}${_mdc_pre}${_mdc_d}"; continue ;;
			esac
		fi
		_tuish_md_span="${_mdc_acc}${_mdc_pre}"
		_tuish_md_rest="$_mdc_r"
		return 0
	done
}

# _tuish_md_inline TEXT -> _tuish_md_pay
#
# Prefix-scan for the earliest marker, the same shape hl.sh uses. Markers are
# checked in priority order so that at an equal position ** beats *, which is what
# makes **strong** strong rather than two adjacent emphases.
#
# Link text is handled WITHOUT RECURSION: the remainder is parked in _mdi_tail, the
# link's text becomes the scan input with a base style of 'k', and when it runs out
# the URL is emitted and the tail resumes. Markdown forbids nested links, so one
# level of parking is all that can ever be needed — and a recursive helper would be
# a liability on ksh93, where a POSIX-style function's `local` is a global.
_tuish_md_inline ()
{
	local _mdi_r="$1" _mdi_p _mdi_k _mdi_pre _mdi_t _mdi_n _mdi_bs _mdi_lit
	local _mdi_base=x _mdi_tail='' _mdi_url='' _mdi_in=0

	_tuish_md_pay='' _tuish_md_psty=''

	while :
	do
		if test -z "$_mdi_r"
		then
			if test "$_mdi_in" -eq 1
			then
				_mdi_r="$_mdi_tail" _mdi_tail='' _mdi_url='' _mdi_in=0 _mdi_base=x
				continue
			fi
			break
		fi

		_mdi_p=-1 _mdi_k='' _mdi_pre=''

		case $_mdi_r in *'`'*)
			_mdi_t="${_mdi_r%%"$_TUISH_MD_BT"*}"; _mdi_n=${#_mdi_t}
			if test "$_mdi_p" -lt 0 || test "$_mdi_n" -lt "$_mdi_p"
			then _mdi_p=$_mdi_n _mdi_k=code _mdi_pre="$_mdi_t"; fi ;;
		esac
		case $_mdi_r in *'!['*)
			_mdi_t="${_mdi_r%%'!['*}"; _mdi_n=${#_mdi_t}
			if test "$_mdi_p" -lt 0 || test "$_mdi_n" -lt "$_mdi_p"
			then _mdi_p=$_mdi_n _mdi_k=img _mdi_pre="$_mdi_t"; fi ;;
		esac
		if test "$_mdi_in" -eq 0
		then
			case $_mdi_r in *'['*)
				_mdi_t="${_mdi_r%%'['*}"; _mdi_n=${#_mdi_t}
				if test "$_mdi_p" -lt 0 || test "$_mdi_n" -lt "$_mdi_p"
				then _mdi_p=$_mdi_n _mdi_k=link _mdi_pre="$_mdi_t"; fi ;;
			esac
		fi
		case $_mdi_r in *'**'*)
			_mdi_t="${_mdi_r%%'**'*}"; _mdi_n=${#_mdi_t}
			if test "$_mdi_p" -lt 0 || test "$_mdi_n" -lt "$_mdi_p"
			then _mdi_p=$_mdi_n _mdi_k=strong _mdi_pre="$_mdi_t"; fi ;;
		esac
		case $_mdi_r in *'*'*)
			_mdi_t="${_mdi_r%%'*'*}"; _mdi_n=${#_mdi_t}
			if test "$_mdi_p" -lt 0 || test "$_mdi_n" -lt "$_mdi_p"
			then _mdi_p=$_mdi_n _mdi_k=em _mdi_pre="$_mdi_t"; fi ;;
		esac
		case $_mdi_r in *'_'*)
			_mdi_t="${_mdi_r%%'_'*}"; _mdi_n=${#_mdi_t}
			if test "$_mdi_p" -lt 0 || test "$_mdi_n" -lt "$_mdi_p"
			then _mdi_p=$_mdi_n _mdi_k=us _mdi_pre="$_mdi_t"; fi ;;
		esac

		if test "$_mdi_p" -lt 0
		then
			_tuish_md_seg "$_mdi_base" "$_mdi_r"
			_mdi_r=''
			continue
		fi

		case $_mdi_k in
			code)   _mdi_lit='`'  ;;
			img)    _mdi_lit='![' ;;
			link)   _mdi_lit='['  ;;
			strong) _mdi_lit='**' ;;
			em)     _mdi_lit='*'  ;;
			*)      _mdi_lit='_'  ;;
		esac

		# A backslash run of ODD length before the marker escapes it.
		_mdi_bs="${_mdi_pre##*[!\\]}"
		if test $(( ${#_mdi_bs} % 2 )) -eq 1
		then
			_tuish_md_seg "$_mdi_base" "${_mdi_pre%?}${_mdi_lit}"
			_mdi_r="${_mdi_r#"$_mdi_pre""$_mdi_lit"}"
			continue
		fi

		_mdi_t="${_mdi_r#"$_mdi_pre""$_mdi_lit"}"

		case $_mdi_k in
			code)
				if _tuish_md_close '`' "$_mdi_t" 0
				then
					_tuish_md_seg "$_mdi_base" "$_mdi_pre"
					_tuish_md_seg m "$_tuish_md_span"
					_mdi_r="$_tuish_md_rest"
				else
					_tuish_md_seg "$_mdi_base" "${_mdi_pre}${_mdi_lit}"
					_mdi_r="$_mdi_t"
				fi ;;
			img)
				# An inline image degrades to its alt text; a standalone image is a
				# block and never reaches this scanner.
				if _tuish_md_close '](' "$_mdi_t" 0
				then
					_mdi_n="$_tuish_md_span"
					if _tuish_md_close ')' "$_tuish_md_rest" 0
					then
						_tuish_md_seg "$_mdi_base" "${_mdi_pre}${_mdi_n}"
						_mdi_r="$_tuish_md_rest"
					else
						_tuish_md_seg "$_mdi_base" "${_mdi_pre}${_mdi_lit}"
						_mdi_r="$_mdi_t"
					fi
				else
					_tuish_md_seg "$_mdi_base" "${_mdi_pre}${_mdi_lit}"
					_mdi_r="$_mdi_t"
				fi ;;
			link)
				if _tuish_md_close '](' "$_mdi_t" 0
				then
					_mdi_n="$_tuish_md_span"
					if _tuish_md_close ')' "$_tuish_md_rest" 0
					then
						_tuish_md_seg "$_mdi_base" "$_mdi_pre"
						_mdi_url="$_tuish_md_span"
						_mdi_tail="$_tuish_md_rest"
						# The URL is emitted BEFORE the link text, which is what
						# makes the link's extent unambiguous: it opens here and
						# closes at the next 'x'. Emitting it after instead left a
						# link whose text begins with markup — [*Like this*](url) —
						# with no 'k' segment at all, and therefore no detectable
						# start; the emphasis escaped the anchor and the anchor
						# came out empty.
						_tuish_md_seg u "$_mdi_url"
						_mdi_r="$_mdi_n" _mdi_base=k _mdi_in=1
						# An empty link text shows the URL, as browsers do.
						if test -z "$_mdi_r"; then _mdi_r="$_mdi_url"; fi
					else
						_tuish_md_seg "$_mdi_base" "${_mdi_pre}${_mdi_lit}"
						_mdi_r="$_mdi_t"
					fi
				else
					_tuish_md_seg "$_mdi_base" "${_mdi_pre}${_mdi_lit}"
					_mdi_r="$_mdi_t"
				fi ;;
			strong)
				if _tuish_md_close '**' "$_mdi_t" 0
				then
					_tuish_md_seg "$_mdi_base" "$_mdi_pre"
					_tuish_md_seg s "$_tuish_md_span"
					_mdi_r="$_tuish_md_rest"
				else
					_tuish_md_seg "$_mdi_base" "${_mdi_pre}${_mdi_lit}"
					_mdi_r="$_mdi_t"
				fi ;;
			em)
				if _tuish_md_close '*' "$_mdi_t" 0
				then
					_tuish_md_seg "$_mdi_base" "$_mdi_pre"
					_tuish_md_seg e "$_tuish_md_span"
					_mdi_r="$_tuish_md_rest"
				else
					_tuish_md_seg "$_mdi_base" "${_mdi_pre}${_mdi_lit}"
					_mdi_r="$_mdi_t"
				fi ;;
			us)
				# The OPENER needs a boundary too. Without it the '_' inside an
				# identifier opens an emphasis whose gated closer then never arrives,
				# and the whole run degrades to literal text one marker at a time.
				_mdi_n="${_mdi_pre#"${_mdi_pre%?}"}"
				case $_mdi_n in
					''|[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_]) : ;;
					*)
						_tuish_md_seg "$_mdi_base" "${_mdi_pre}${_mdi_lit}"
						_mdi_r="$_mdi_t"
						continue ;;
				esac
				if _tuish_md_close '_' "$_mdi_t" 1
				then
					_tuish_md_seg "$_mdi_base" "$_mdi_pre"
					_tuish_md_seg e "$_tuish_md_span"
					_mdi_r="$_tuish_md_rest"
				else
					_tuish_md_seg "$_mdi_base" "${_mdi_pre}${_mdi_lit}"
					_mdi_r="$_mdi_t"
				fi ;;
		esac
	done
	return 0
}

# _tuish_md_plain TEXT -> _tuish_md_text : the same text with markup removed.
# Headings, captions and entry titles are plain-text records, so they need the
# markers gone without the segment machinery.
_tuish_md_plain ()
{
	local _mdp_r _mdp_s _mdp_t
	_tuish_md_inline "$1"
	_mdp_r="$_tuish_md_pay" _tuish_md_text=''
	while test -n "$_mdp_r"
	do
		_mdp_s="${_mdp_r%%${_TUISH_MD_US}*}"
		_mdp_r="${_mdp_r#*${_TUISH_MD_US}}"
		case $_mdp_r in
			*${_TUISH_MD_US}*) _mdp_t="${_mdp_r%%${_TUISH_MD_US}*}"; _mdp_r="${_mdp_r#*${_TUISH_MD_US}}" ;;
			*)                 _mdp_t="$_mdp_r"; _mdp_r='' ;;
		esac
		# A link's URL is decoration here, not text.
		if test "$_mdp_s" != u; then _tuish_md_text="${_tuish_md_text}${_mdp_t}"; fi
	done
	return 0
}

# _tuish_md_entry TEXT — emit an 'e' record when TEXT is a list item pointing at a
# local document. Returns 1 for an ordinary bullet.
#
# The discriminator is the link TARGET, not the list shape: a home page's Links
# section is the same markdown pointing at external URLs, and stays bullets.
_tuish_md_entry ()
{
	local _mde_t="$1" _mde_title _mde_url _mde_rest _mde_base _mde_date
	case $_mde_t in
		'['*']('*')'*) : ;;
		*) return 1 ;;
	esac

	_mde_title="${_mde_t#"["}"
	_mde_title="${_mde_title%%"]("*}"
	_mde_url="${_mde_t#*"]("}"
	_mde_rest="${_mde_url#*")"}"
	_mde_url="${_mde_url%%")"*}"

	case $_mde_url in
		/blog/*.md)           _mde_base="${_mde_url#/blog/}"; _mde_base="${_mde_base%.md}" ;;
		/blog.md|/blog.pt.md) _mde_base='@blog' ;;
		*) return 1 ;;
	esac

	# The title may carry emphasis — the "More entries..." sentinel does.
	_tuish_md_plain "$_mde_title"; _mde_title="$_tuish_md_text"

	# The date is whatever trails the link, minus the separator and any emphasis.
	_mde_date="$_mde_rest"
	while :
	do
		case $_mde_date in
			' '*)  _mde_date="${_mde_date# }" ;;
			'—'*) _mde_date="${_mde_date#—}" ;;
			'–'*) _mde_date="${_mde_date#–}" ;;
			'-'*)  _mde_date="${_mde_date#-}" ;;
			*) break ;;
		esac
	done
	if test -n "$_mde_date"
	then _tuish_md_plain "$_mde_date"; _mde_date="$_tuish_md_text"
	fi

	tuish_md_emit e "${_mde_base}${_TUISH_MD_US}${_mde_title}${_TUISH_MD_US}${_mde_date}"
	return 0
}

# _tuish_md_flush — close the open block and emit it.
_tuish_md_flush ()
{
	local _mdx_s="$_tuish_md_pend" _mdx_a="$_tuish_md_acc"
	if test -z "$_mdx_s"; then return 0; fi
	_tuish_md_pend='' _tuish_md_acc=''

	# A lone italic paragraph directly under an image is that image's caption.
	if test "$_mdx_s" = p && test "$_tuish_md_last" = g
	then
		case $_mdx_a in
			'*'*'*')
				_tuish_md_plain "$_mdx_a"
				tuish_md_emit d "$_tuish_md_text"
				_tuish_md_last=d
				return 0 ;;
		esac
	fi

	if test "$_mdx_s" = b && test "$TUISH_MD_ENTRIES" -eq 1
	then
		if _tuish_md_entry "$_mdx_a"; then _tuish_md_last=e; return 0; fi
	fi

	_tuish_md_inline "$_mdx_a"
	tuish_md_emit "$_mdx_s" "$_tuish_md_pay"
	_tuish_md_last="$_mdx_s"
	return 0
}

# _tuish_md_heading LEVEL TEXT — markdown level N becomes HTML level N+1, because
# <h1> is the site wordmark, not a document heading.
_tuish_md_heading ()
{
	local _mdh_l=$1 _mdh_a _mdh_d
	_tuish_md_plain "$2"
	if test "$_mdh_l" -eq 1 && test "$_tuish_md_mode" = post && test "$_tuish_md_seen_t" -eq 0
	then
		_tuish_md_seen_t=1
		tuish_md_emit t "$_tuish_md_text"
		_tuish_md_last=t
		if test "$TUISH_MD_BYLINE" -eq 1
		then
			tuish_md_meta author; _mdh_a="$TUISH_MD_META"
			tuish_md_meta date;   _mdh_d="$TUISH_MD_META"
			if test -n "$_mdh_a" && test -n "$_mdh_d"
			then
				tuish_md_emit i "$_mdh_a – $_mdh_d"
				_tuish_md_last=i
			fi
		fi
		return 0
	fi
	tuish_md_emit "h$(( _mdh_l + 1 ))" "$_tuish_md_text"
	_tuish_md_last=h
	return 0
}

# _tuish_md_rule LINE — is this a thematic break? Three or more of one marker,
# spaces allowed between them.
_tuish_md_rule ()
{
	local _mdr_s="$1"
	while :
	do
		case $_mdr_s in
			*' '*) _mdr_s="${_mdr_s%% *}${_mdr_s#* }" ;;
			*) break ;;
		esac
	done
	if test ${#_mdr_s} -lt 3; then return 1; fi
	case $_mdr_s in *[!-]*) : ;; *) return 0 ;; esac
	case $_mdr_s in *[!*]*) : ;; *) return 0 ;; esac
	case $_mdr_s in *[!_]*) : ;; *) return 0 ;; esac
	return 1
}

# _tuish_md_sanitize LINE -> _tuish_md_text
# Drops US and strips one trailing CR, so CRLF sources parse.
#
# TABS ARE KEPT ON PURPOSE. A record is split on its FIRST tab — `${l%%<TAB>*}`
# takes the shortest prefix, `${l#*<TAB>}` everything past it — so further tabs
# inside a payload are carried through untouched. US is different: it separates
# fields *within* a payload and is consumed iteratively, so one in the source would
# genuinely reframe the segments.
#
# Keeping tabs is what makes a copied code snippet byte-exact. A renderer that
# cannot draw one — a terminal canvas, where a raw tab jumps to the next tab stop
# and breaks the layout — expands it at PAINT time, which leaves the clipboard
# holding what the author actually wrote.
_tuish_md_sanitize ()
{
	local _mds_l="$1"
	case $_mds_l in
		*"$_TUISH_MD_CR") _mds_l="${_mds_l%"$_TUISH_MD_CR"}" ;;
	esac
	case $_mds_l in
		*"$_TUISH_MD_US"*)
			while :
			do
				case $_mds_l in
					*"$_TUISH_MD_US"*) _mds_l="${_mds_l%%"$_TUISH_MD_US"*}${_mds_l#*"$_TUISH_MD_US"}" ;;
					*) break ;;
				esac
			done ;;
	esac
	_tuish_md_text="$_mds_l"
	return 0
}

# _tuish_md_frontmatter LINE — parse one front-matter line.
_tuish_md_frontmatter ()
{
	local _mdm_l="$1" _mdm_k _mdm_v
	case $_mdm_l in
		'---'|'...') _tuish_md_fm=0; return 0 ;;
		*':'*) : ;;
		*) return 0 ;;
	esac
	_mdm_k="${_mdm_l%%:*}"
	_mdm_v="${_mdm_l#*:}"
	_mdm_v="${_mdm_v# }"
	case $_mdm_v in
		'"'*'"') _mdm_v="${_mdm_v#\"}"; _mdm_v="${_mdm_v%\"}" ;;
		"'"*"'") _mdm_v="${_mdm_v#\'}"; _mdm_v="${_mdm_v%\'}" ;;
	esac
	# Only identifier keys become variables, and the value is assigned FROM a
	# variable rather than interpolated — so nothing in a document can smuggle
	# shell into the eval.
	case $_mdm_k in
		''|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_]*) return 0 ;;
	esac
	eval "_tuish_md_m_$_mdm_k=\$_mdm_v"
	TUISH_MD_KEYS="$TUISH_MD_KEYS $_mdm_k"
	tuish_md_emit f "${_mdm_k}${_TUISH_MD_US}${_mdm_v}"
	return 0
}

# tuish_md_meta KEY -> TUISH_MD_META ('' when the key is absent)
tuish_md_meta ()
{
	eval "TUISH_MD_META=\${_tuish_md_m_$1:-}"
	return 0
}

# tuish_md_feed LINE
tuish_md_feed ()
{
	local _mdf_l _mdf_t _mdf_a _mdf_s

	_tuish_md_sanitize "$1"
	_mdf_l="$_tuish_md_text"

	if test "$_tuish_md_fm" -eq 1
	then
		_tuish_md_frontmatter "$_mdf_l"
		return 0
	fi

	# --- fenced code ---------------------------------------------------------
	if test "$_tuish_md_code" -eq 1
	then
		case $_mdf_l in
			'```'*) _tuish_md_code=0; return 0 ;;
		esac
		if command -v tuish_hl_line >/dev/null 2>&1
		then tuish_hl_line "$_mdf_l"; tuish_md_emit c "$TUISH_HL_PAY"
		else tuish_md_emit c ".${_TUISH_MD_US}${_mdf_l}"
		fi
		_tuish_md_last=c
		return 0
	fi
	case $_mdf_l in
		'```'*)
			_tuish_md_flush
			_mdf_t="${_mdf_l#"$_TUISH_MD_BT$_TUISH_MD_BT$_TUISH_MD_BT"}"
			if command -v tuish_hl_begin >/dev/null 2>&1
			then tuish_hl_begin "$_mdf_t"
			fi
			# 'cb' marks where a block STARTS, which a run of 'c' records cannot.
			# Two fences with nothing between them produce contiguous 'c' records,
			# so a renderer detecting runs alone would silently weld them into one
			# card — and back-to-back blocks are a real thing authors write.
			tuish_md_emit cb "$_mdf_t"
			_tuish_md_code=1
			_tuish_md_last=cb
			return 0 ;;
	esac

	# A quote block ends at the first line that is not a '>' line — including a
	# blank one, which is not a '>' line either.
	case $_mdf_l in
		'>'*) : ;;
		*) _tuish_md_inq=0 ;;
	esac

	# --- HTML comments -------------------------------------------------------
	# Skipped wherever they appear. Checked AFTER the fence handling above, so a
	# comment written inside a code block stays code.
	#
	# This is what lets a licence header sit at the top of a document: REUSE wants
	# SPDX tags in a comment, and markdown's comment is HTML's. Without it the
	# header would render as a paragraph reading "<!--".
	if test "$_tuish_md_com" -eq 1
	then
		case $_mdf_l in *'-->'*) _tuish_md_com=0 ;; esac
		return 0
	fi
	case $_mdf_l in
		'<!--'*)
			case $_mdf_l in
				*'-->'*) : ;;
				*) _tuish_md_com=1 ;;
			esac
			return 0 ;;
	esac

	# --- blank ---------------------------------------------------------------
	case $_mdf_l in
		*[!\ ]*) : ;;
		*) _tuish_md_flush; return 0 ;;
	esac

	# --- front-matter opener -------------------------------------------------
	# Legal until the first CONTENT line, rather than strictly at line 1: a licence
	# header is a comment, and comments and blank lines have already returned above,
	# so anything reaching here is content and closes the window.
	if test "$_tuish_md_body" -eq 0
	then
		_tuish_md_body=1
		if test "$_mdf_l" = '---'
		then
			_tuish_md_fm=1
			return 0
		fi
	fi

	# --- headings ------------------------------------------------------------
	case $_mdf_l in
		'#### '*) _tuish_md_flush; _tuish_md_heading 4 "${_mdf_l#"#### "}"; return 0 ;;
		'### '*)  _tuish_md_flush; _tuish_md_heading 3 "${_mdf_l#"### "}";  return 0 ;;
		'## '*)   _tuish_md_flush; _tuish_md_heading 2 "${_mdf_l#"## "}";   return 0 ;;
		'# '*)    _tuish_md_flush; _tuish_md_heading 1 "${_mdf_l#"# "}";    return 0 ;;
	esac

	# --- thematic break ------------------------------------------------------
	if _tuish_md_rule "$_mdf_l"
	then
		_tuish_md_flush
		tuish_md_emit r ''
		_tuish_md_last=r
		return 0
	fi

	# --- standalone image ----------------------------------------------------
	case $_mdf_l in
		'!['*']('*')')
			_tuish_md_flush
			_mdf_t="${_mdf_l#"!["}"
			_mdf_a="${_mdf_t%%"]("*}"
			_mdf_s="${_mdf_t#*"]("}"; _mdf_s="${_mdf_s%")"}"
			tuish_md_emit g "${_mdf_a}${_TUISH_MD_US}${_mdf_s}"
			_tuish_md_last=g
			return 0 ;;
	esac

	# --- blockquote ----------------------------------------------------------
	# A quote block can hold several paragraphs, separated by a bare '>'. Each
	# becomes its own 'q' record, and 'qb' marks where a NEW quote starts — the
	# same job 'cb' does for code, and needed for the same reason: two adjacent
	# quotes produce adjacent 'q' records that a run-watching renderer would
	# otherwise weld into one.
	case $_mdf_l in
		'>'*)
			_mdf_t="${_mdf_l#>}"; _mdf_t="${_mdf_t# }"
			if test "$_tuish_md_inq" -eq 0
			then
				_tuish_md_flush
				tuish_md_emit qb ''
				_tuish_md_inq=1
			fi
			if test -z "$_mdf_t"
			then _tuish_md_flush
			elif test "$_tuish_md_pend" = q
			then _tuish_md_acc="$_tuish_md_acc $_mdf_t"
			else _tuish_md_pend=q _tuish_md_acc="$_mdf_t"
			fi
			return 0 ;;
	esac

	# --- list items ----------------------------------------------------------
	_mdf_t="${_mdf_l#"${_mdf_l%%[! ]*}"}"          # drop leading indentation
	case $_mdf_t in
		'- '*|'* '*|'+ '*)
			_tuish_md_flush
			_tuish_md_pend=b _tuish_md_acc="${_mdf_t#? }"
			return 0 ;;
		[0-9]*'. '*)
			_mdf_a="${_mdf_t%%.*}"
			case $_mdf_a in
				*[!0123456789]*) : ;;
				*)
					_tuish_md_flush
					_tuish_md_pend=n _tuish_md_acc="${_mdf_t#*. }"
					return 0 ;;
			esac ;;
	esac

	# --- paragraph, with lazy continuation -----------------------------------
	if test -n "$_tuish_md_pend"
	then _tuish_md_acc="$_tuish_md_acc $_mdf_l"
	else _tuish_md_pend=p _tuish_md_acc="$_mdf_l"
	fi
	return 0
}

# tuish_md_end — flush whatever block is still open.
tuish_md_end ()
{
	_tuish_md_flush
	_tuish_md_code=0 _tuish_md_fm=0
	return 0
}

# tuish_md_file FILE [MODE]
# A FILE REDIRECT, never a pipe: the loop has to stay in the caller's shell so the
# parser's state and the caller's own globals both survive it.
tuish_md_file ()
{
	local _mdr_l
	tuish_md_begin "${2:-post}"
	while IFS= read -r _mdr_l || test -n "$_mdr_l"
	do
		tuish_md_feed "$_mdr_l"
	done < "$1"
	tuish_md_end
	return 0
}
