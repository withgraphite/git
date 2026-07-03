#!/bin/sh

test_description='incremental multi-pack-index'

. ./test-lib.sh
. "$TEST_DIRECTORY"/lib-midx.sh

GIT_TEST_MULTI_PACK_INDEX=0
export GIT_TEST_MULTI_PACK_INDEX

objdir=.git/objects
packdir=$objdir/pack
midxdir=$packdir/multi-pack-index.d
midx_chain=$midxdir/multi-pack-index-chain

test_expect_success 'convert non-incremental MIDX to incremental' '
	test_commit base &&
	git config set maintenance.auto false &&
	git repack -ad &&
	git multi-pack-index write &&

	test_path_is_file $packdir/multi-pack-index &&
	old_hash="$(midx_checksum $objdir)" &&

	test_commit other &&
	git repack -d &&
	git multi-pack-index write --incremental &&

	test_path_is_missing $packdir/multi-pack-index &&
	test_path_is_file $midx_chain &&
	test_line_count = 2 $midx_chain &&
	grep $old_hash $midx_chain
'

compare_results_with_midx 'incremental MIDX'

test_expect_success 'convert incremental to non-incremental' '
	test_commit squash &&
	git repack -d &&
	git multi-pack-index write &&

	test_path_is_file $packdir/multi-pack-index &&
	test_dir_is_empty $midxdir
'

compare_results_with_midx 'non-incremental MIDX conversion'

write_midx_layer () {
	n=1
	if test -f $midx_chain
	then
		n="$(($(wc -l <$midx_chain) + 1))"
	fi

	for i in 1 2
	do
		test_commit $n.$i &&
		git repack -d || return 1
	done &&
	git multi-pack-index write --bitmap --incremental
}

test_expect_success 'write initial MIDX layer' '
	git repack -ad &&
	write_midx_layer
'

test_expect_success 'read bitmap from first MIDX layer' '
	git rev-list --test-bitmap 1.2
'

test_expect_success 'write another MIDX layer' '
	test_env GIT_TRACE2_EVENT="$(pwd)/bitmap-reuse.trace" \
		write_midx_layer &&
	test_trace2_data pack-bitmap-write base_bitmap_positions_stable 1 \
		<bitmap-reuse.trace &&
	test_grep -E "\"key\":\"building_bitmaps_reused\",\"value\":\"[1-9][0-9]*\"" \
		bitmap-reuse.trace
'

test_expect_success 'midx verify with multiple layers' '
	test_path_is_file "$midx_chain" &&
	test_line_count = 2 "$midx_chain" &&

	git multi-pack-index verify
'

test_expect_success 'read bitmap from second MIDX layer' '
	git rev-list --test-bitmap 2.2
'

test_expect_success 'read earlier bitmap from second MIDX layer' '
	git rev-list --test-bitmap 1.2
'

test_expect_success 'incremental bitmap walk stops at base MIDX commits' '
	git init base-boundary &&
	(
		cd base-boundary &&
		test_commit base &&
		git config set maintenance.auto false &&
		git repack -ad &&
		git multi-pack-index write --bitmap &&

		test_commit tip &&
		git repack -d &&
		GIT_TRACE2_EVENT="$(pwd)/trace" \
			git multi-pack-index write --bitmap --incremental &&

		test_trace2_data midx bitmap_commits_visited 2 <trace &&
		test_trace2_data midx bitmap_base_boundary_hits 1 <trace &&
		test_trace2_data midx bitmap_commits_retained 1 <trace &&
		git multi-pack-index verify &&
		git rev-list --test-bitmap tip
	)
'

test_expect_success 'incremental bitmap works with unbitmapped base' '
	git init unbitmapped-base &&
	(
		cd unbitmapped-base &&
		test_commit base &&
		git config set maintenance.auto false &&
		git repack -ad &&
		git multi-pack-index write --bitmap &&
		base_hash="$(midx_checksum .git/objects)" &&
		rm "$packdir/multi-pack-index-$base_hash.bitmap" &&

		test_commit tip &&
		git repack -d &&
		GIT_TRACE2_EVENT="$(pwd)/trace" \
			git multi-pack-index write --bitmap --incremental &&

		test_trace2_data pack-bitmap-write \
			base_bitmap_positions_stable 0 <trace &&
		git multi-pack-index verify
	)
'

test_expect_success 'show object from first pack' '
	git cat-file -p 1.1
'

test_expect_success 'show object from second pack' '
	git cat-file -p 2.2
'

test_expect_success 'write MIDX layer with --no-write-chain-file' '
	test_commit no-write-chain-file &&
	git repack -d &&

	cp "$midx_chain" "$midx_chain.bak" &&
	layer="$(git multi-pack-index write --bitmap --incremental \
		--no-write-chain-file)" &&

	test_cmp "$midx_chain.bak" "$midx_chain" &&
	test_path_is_file "$midxdir/multi-pack-index-$layer.midx"
'

test_expect_success 'write non-incremental MIDX layer with --no-write-chain-file' '
	test_must_fail git multi-pack-index write --bitmap --no-write-chain-file 2>err &&
	test_grep "cannot use --no-write-chain-file without --incremental" err
'

test_expect_success 'write MIDX layer with --base without --no-write-chain-file' '
	test_must_fail git multi-pack-index write --bitmap --incremental \
		--base=none 2>err &&
	test_grep "cannot use --base without --no-write-chain-file" err
'

test_expect_success 'write MIDX layer with --base=none and --no-write-chain-file' '
	test_commit base-none &&
	git repack -d &&

	cp "$midx_chain" "$midx_chain.bak" &&
	layer="$(git multi-pack-index write --bitmap --incremental \
		--no-write-chain-file --base=none)" &&

	test_cmp "$midx_chain.bak" "$midx_chain" &&
	test_path_is_file "$midxdir/multi-pack-index-$layer.midx"
'

test_expect_success 'write MIDX layer with --base=<hash> and --no-write-chain-file' '
	test_commit base-hash &&
	git repack -d &&

	cp "$midx_chain" "$midx_chain.bak" &&
	layer="$(git multi-pack-index write --bitmap --incremental \
		--no-write-chain-file --base="$(nth_line 1 "$midx_chain")")" &&

	test_cmp "$midx_chain.bak" "$midx_chain" &&
	test_path_is_file "$midxdir/multi-pack-index-$layer.midx"
'

for reuse in false single multi
do
	test_expect_success "full clone (pack.allowPackReuse=$reuse)" '
		rm -fr clone.git &&

		git config pack.allowPackReuse $reuse &&
		git clone --no-local --bare . clone.git
	'
done

test_expect_success 'relink existing MIDX layer' '
	rm -fr "$midxdir" &&

	GIT_TEST_MIDX_WRITE_REV=1 git multi-pack-index write --bitmap &&

	midx_hash="$(test-tool read-midx --checksum $objdir)" &&

	test_path_is_file "$packdir/multi-pack-index" &&
	test_path_is_file "$packdir/multi-pack-index-$midx_hash.bitmap" &&
	test_path_is_file "$packdir/multi-pack-index-$midx_hash.rev" &&

	test_commit another &&
	git repack -d &&
	git multi-pack-index write --bitmap --incremental &&

	test_path_is_missing "$packdir/multi-pack-index" &&
	test_path_is_missing "$packdir/multi-pack-index-$midx_hash.bitmap" &&
	test_path_is_missing "$packdir/multi-pack-index-$midx_hash.rev" &&

	test_path_is_file "$midxdir/multi-pack-index-$midx_hash.midx" &&
	test_path_is_file "$midxdir/multi-pack-index-$midx_hash.bitmap" &&
	test_path_is_file "$midxdir/multi-pack-index-$midx_hash.rev" &&
	test_line_count = 2 "$midx_chain"

'

test_expect_success 'non-incremental write with existing incremental chain' '
	git init non-incremental-write-with-existing &&
	test_when_finished "rm -fr non-incremental-write-with-existing" &&

	(
		cd non-incremental-write-with-existing &&

		git config set maintenance.auto false &&

		write_midx_layer &&
		write_midx_layer &&

		git multi-pack-index write
	)
'

test_expect_success 'non-incremental bitmap write to alternate object dir with mixed chain' '
	git init alternate-object-dir-with-existing &&
	test_when_finished "rm -fr alternate-object-dir-with-existing" &&

	(
		cd alternate-object-dir-with-existing &&
		git config set maintenance.auto false &&

		test_commit base &&
		git repack -ad &&
		git multi-pack-index write --bitmap &&
		base_hash="$(midx_checksum .git/objects)" &&
		rm "$packdir/multi-pack-index-$base_hash.bitmap" &&

		test_commit tip &&
		git repack -d &&
		git multi-pack-index write --incremental --bitmap &&

		mkdir -p stage-objects/pack &&
		ln "$packdir"/*.pack "$packdir"/*.idx stage-objects/pack &&
		git multi-pack-index write --bitmap \
			--object-dir="$(pwd)/stage-objects" &&
		git multi-pack-index verify \
			--object-dir="$(pwd)/stage-objects"
	)
'

test_done
