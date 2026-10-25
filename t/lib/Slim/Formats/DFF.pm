package Slim::Formats::DFF;
use strict; use warnings;
use base qw(Slim::Formats::DSD);
sub getInitialAudioBlock { return '' }
sub findFrameBoundaries { return 0 }
1;
