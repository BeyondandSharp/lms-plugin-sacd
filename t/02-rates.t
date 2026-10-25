use strict;
use warnings;
use Test::More;
use lib 'lib';
use Plugins::SACDPlayer::Rates qw(pcm_target dop_rate dop_possible dsd_label dst_frame_bytes);

is(dsd_label(2822400), 'DSD64', 'DSD64 label');
is(dsd_label(11289600), 'DSD256', 'DSD256 label');
is(dop_rate(2822400), 176400, 'DSD64 DoP rate');
is(dop_rate(5644800), 352800, 'DSD128 DoP rate');
is(dst_frame_bytes(2822400), 4704, 'DSD64 DST frame bytes');
is(dst_frame_bytes(11289600), 18816, 'DSD256 DST frame bytes');

is(pcm_target(2822400, 0, 'auto'), 352800, 'DSD64 PCM target');
is(pcm_target(5644800, 192000, 'auto'), 176400, 'DSD128 target clamped to 176.4');
is(pcm_target(11289600, 96000, 'auto'), 88200, 'DSD256 target 88.2');
is(pcm_target(2822400, 384000, '176400'), 176400, 'explicit 176.4');
is(pcm_target(2822400, 48000, 'auto'), 44100, 'minimum 44.1');

ok(dop_possible(2822400, 192000, 128), 'DSD64 DoP possible');
ok(!dop_possible(5644800, 192000, 128), 'DSD128 DoP exceeds 192k');
ok(dop_possible(5644800, 384000, 128), 'DSD128 DoP on 384k player');
ok(!dop_possible(11289600, 768000, 128), 'DSD256 capped by dop_max_fs');

done_testing;
