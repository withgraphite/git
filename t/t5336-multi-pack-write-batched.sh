#!/bin/sh

test_description='batched multi-pack-index writes'

. ./test-lib.sh
. "$TEST_DIRECTORY"/lib-midx.sh

GIT_TEST_MULTI_PACK_INDEX=0
GIT_TEST_MULTI_PACK_INDEX_WRITE_INCREMENTAL=0
export GIT_TEST_MULTI_PACK_INDEX
export GIT_TEST_MULTI_PACK_INDEX_WRITE_INCREMENTAL

objdir=.git/objects
packdir=$objdir/pack
midxdir=$packdir/multi-pack-index.d
midx_chain=$midxdir/multi-pack-index-chain

nth_line () {
	sed -n "$1p" "$2"
}

write_pack () {
	test_commit "$1" &&
	git pack-objects --all --unpacked "$packdir/pack-$1" &&
	git prune-packed
}

bitmap_layers_present () {
	while read layer
	do
		test_path_is_file "$midxdir/multi-pack-index-$layer.bitmap" ||
		return 1
	done <"$midx_chain"
}

layer_packs () {
	test-tool read-midx "$objdir" "$1" >out &&
	grep "^pack-" out | sort
}

test_expect_success 'batched write creates incremental layers' '
	git init basic &&
	(
		cd basic &&
		git config maintenance.auto false &&

		write_pack A &&
		write_pack B &&
		write_pack C &&
		write_pack D &&

		git multi-pack-index write --bitmap \
			--max-objects-per-layer=4 &&

		test_path_is_file "$midx_chain" &&
		test_line_count = 4 "$midx_chain" &&
		bitmap_layers_present &&
		git multi-pack-index verify &&
		git rev-list --test-bitmap D
	)
'

test_expect_success 'single oversized pack gets its own root layer' '
	git init oversized &&
	(
		cd oversized &&
		git config maintenance.auto false &&

		test_commit_bulk --id=large 5 &&
		large_idx="$(basename "$packdir"/pack-*.idx)" &&
		write_pack small-one &&
		write_pack small-two &&

		git multi-pack-index write --bitmap \
			--max-objects-per-layer=4 &&

		test_line_count = 3 "$midx_chain" &&
		layer_packs "$(nth_line 1 "$midx_chain")" >actual &&
		echo "$large_idx" >expect &&
		test_cmp expect actual
	)
'

test_expect_success '--stdin-packs writes only requested uncovered packs' '
	git init stdin-packs &&
	(
		cd stdin-packs &&
		git config maintenance.auto false &&

		write_pack A &&
		write_pack B &&
		write_pack C &&

		pack_a="$(basename "$packdir"/pack-A-*.idx)" &&
		pack_b="$(basename "$packdir"/pack-B-*.idx)" &&
		pack_c="$(basename "$packdir"/pack-C-*.idx)" &&

		printf "%s\n" "$pack_a" |
			git multi-pack-index write --incremental --bitmap \
				--stdin-packs &&
		printf "%s\n" "$pack_a" "$pack_b" "$pack_c" |
			git multi-pack-index write --bitmap --stdin-packs \
				--max-objects-per-layer=4 &&

		test_line_count = 3 "$midx_chain" &&
		layer_packs "$(nth_line 2 "$midx_chain")" >actual &&
		echo "$pack_b" >expect &&
		test_cmp expect actual &&
		layer_packs "$(nth_line 3 "$midx_chain")" >actual &&
		echo "$pack_c" >expect &&
		test_cmp expect actual
	)
'

test_expect_success '--preferred-pack is routed to containing batch' '
	git init preferred &&
	(
		cd preferred &&
		git config maintenance.auto false &&

		write_pack A &&
		write_pack B &&
		preferred_pack="$(basename "$packdir"/pack-B-*.pack)" &&

		git multi-pack-index write --bitmap \
			--max-objects-per-layer=4 \
			--preferred-pack="$preferred_pack" 2>err &&
		test_must_be_empty err &&
		test_line_count = 2 "$midx_chain" &&
		bitmap_layers_present
	)
'

test_expect_success 'batched write sees previously written chain layers' '
	git init cache-invalidation &&
	(
		cd cache-invalidation &&
		git config maintenance.auto false &&

		write_pack A &&
		write_pack B &&
		pack_a="$(basename "$packdir"/pack-A-*.idx)" &&
		pack_b="$(basename "$packdir"/pack-B-*.idx)" &&

		printf "%s\n" "$pack_a" |
			git multi-pack-index write --incremental --bitmap \
				--stdin-packs &&
		printf "%s\n" "$pack_b" |
			git multi-pack-index write --incremental --bitmap \
				--stdin-packs &&

		write_pack C &&
		write_pack D &&

		git multi-pack-index write --bitmap \
			--max-objects-per-layer=4 &&

		test_line_count = 4 "$midx_chain" &&
		git multi-pack-index verify
	)
'

test_expect_success 'reject incompatible batched write options' '
	git init incompatible &&
	(
		cd incompatible &&
		write_pack A &&

		test_must_fail git multi-pack-index write \
			--max-objects-per-layer=4 \
			--base=none 2>err &&
		test_grep "cannot use --max-objects-per-layer with --base" err &&

		test_must_fail git multi-pack-index write \
			--max-objects-per-layer=4 \
			--incremental --no-write-chain-file 2>err &&
		test_grep "cannot use --max-objects-per-layer with --no-write-chain-file" err
	)
'

test_done
