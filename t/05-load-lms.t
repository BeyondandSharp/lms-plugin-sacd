use strict;
use warnings;
use Test::More;
use lib 'lib', 't/lib';

BEGIN {
    package main;
    sub SCANNER () { 0 }
    sub DEBUGLOG () { 0 }
}

use_ok('Plugins::SACDPlayer::Transcoder');
use_ok('Plugins::SACDPlayer::Route');
use_ok('Plugins::SACDPlayer::Hooks');
use_ok('Plugins::SACDPlayer::Formats');
use_ok('Plugins::SACDPlayer::Settings');
use_ok('Plugins::SACDPlayer::PlayerSettings');
use_ok('Plugins::SACDPlayer::Plugin');

Plugins::SACDPlayer::Formats->install;
is($Slim::Formats::tagClasses{dsf}, 'Plugins::SACDPlayer::Formats::DSF', 'DSF reader installed');
is($Slim::Formats::tagClasses{dff}, 'Plugins::SACDPlayer::Formats::DFF', 'DFF reader installed');

done_testing;
