use strict;
use warnings;
use Test::More;

use lib 'lib';
use_ok('Plugins::SACDPlayer::DFFParser');
use_ok('Plugins::SACDPlayer::ID3');
use_ok('Plugins::SACDPlayer::Rates');
use_ok('Plugins::SACDPlayer::TagReader');

done_testing;
