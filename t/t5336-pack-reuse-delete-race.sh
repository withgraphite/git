#!/bin/sh

test_description='pack-objects survives concurrent source pack deletion'

. ./test-lib.sh

GIT_TEST_MULTI_PACK_INDEX=0
GIT_TEST_MULTI_PACK_INDEX_WRITE_INCREMENTAL=0

# Stall pack-objects after pins land (first output byte proves the write is
# underway), delete the source packs with a concurrent repack, then resume.
# Hold the FIFO read end open across the repack; do not reopen the FIFO after
# the writer may have died. Use fd 8 so we do not collide with test-lib's fd 3.
#
# Packs must be larger than the pipe buffer so pack-objects blocks mid-write
# with pins still held; otherwise it finishes (and unpins) before we can race.
#
# usage: run_pack_race <trace-key> [--stdin <file>] [pack-objects-args...]
run_pack_race () {
	trace_key="$1"
	shift
	stdin_file=/dev/null
	if test "$1" = "--stdin"
	then
		stdin_file="$2"
		shift 2
	fi

	fifo="$PWD/pack-race.fifo" &&
	rm -f "$fifo" result.pack result.idx trace2.txt err &&
	mkfifo "$fifo" &&
	: >trace2.txt || return 1

	GIT_TRACE2_EVENT="$PWD/trace2.txt" \
		git -c core.packedGitLimit=1 pack-objects --stdout "$@" \
			<"$stdin_file" >"$fifo" 2>err &
	pid=$! &&

	exec 8<"$fifo" &&
	dd bs=1 count=1 <&8 >result.pack 2>/dev/null &&
	git repack -adq &&
	cat <&8 >>result.pack &&
	exec 8<&- &&
	wait $pid &&
	! grep -i warning: err &&
	! grep "Too many open files" err &&
	! grep "cannot be accessed" err &&
	grep "\"key\":\"$trace_key\"" trace2.txt &&
	git index-pack --strict -o result.idx result.pack
}

# Two packs, each big enough to keep pack-objects blocked on the FIFO.
setup_two_large_packs () {
	test-tool genrandom A 262144 >blob-a &&
	git add blob-a &&
	test_tick &&
	git commit -m A &&
	git repack -d &&
	test-tool genrandom B 262144 >blob-b &&
	git add blob-b &&
	test_tick &&
	git commit -m B &&
	git repack -d &&
	test $(ls .git/objects/pack/pack-*.pack | wc -l) -ge 2
}

test_expect_success PIPE 'bitmap pack-reuse survives source pack deletion' '
	git init reuse &&
	(
		cd reuse &&
		git config pack.allowPackReuse multi &&
		setup_two_large_packs &&
		git multi-pack-index write --bitmap &&

		run_pack_race read-pin/reuse-vanished \
			--revs --all --delta-base-offset
	)
'

test_expect_success PIPE 'generic reads survive source pack deletion' '
	git init read-race &&
	(
		cd read-race &&
		setup_two_large_packs &&
		git multi-pack-index write &&
		git prune-packed &&

		git config pack.allowPackReuse false &&
		git rev-list --objects --all | cut -d" " -f1 >objects &&

		run_pack_race read-pin/vanished --stdin objects
	)
'

test_expect_success PIPE,ULIMIT_FILE_DESCRIPTORS 'pin failure under fd pressure degrades to a miss' '
	git init fd-limit &&
	(
		cd fd-limit &&
		git config pack.allowPackReuse multi &&
		mkdir -p .git/objects/pack &&
		: >tree &&
		for i in $(test_seq 1 48)
		do
			oid=$(echo "$i" | git hash-object -w --stdin) &&
			echo "$oid" | git pack-objects .git/objects/pack/pack &&
			printf "100644 blob %s\tfile-%s\n" "$oid" "$i" >>tree ||
			return 1
		done &&
		tree_oid=$(git mktree <tree) &&
		commit=$(echo commit | git commit-tree "$tree_oid") &&
		git update-ref refs/heads/main "$commit" &&
		git repack -d &&
		git prune-packed &&
		git multi-pack-index write --bitmap &&

		fifo="$PWD/pack-race.fifo" &&
		rm -f "$fifo" result.pack result.idx err &&
		mkfifo "$fifo" || return 1

		(
			ulimit -n 64 &&
			git -c core.packedGitLimit=1 pack-objects --stdout \
				--revs --all --delta-base-offset \
				</dev/null >"$fifo" 2>err
		) &
		pid=$! &&

		exec 8<"$fifo" &&
		dd bs=1 count=1 <&8 >result.pack 2>/dev/null &&
		git repack -adq &&
		cat <&8 >>result.pack &&
		exec 8<&- &&
		wait $pid &&
		! grep "Too many open files" err &&
		! grep -i warning: err &&
		git index-pack --strict -o result.idx result.pack
	)
'

test_done
