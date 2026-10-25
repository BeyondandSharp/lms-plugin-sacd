package Slim::Player::CapabilitiesHelper;
use strict; use warnings;
our $FORMATS = [qw(flc pcm wav dsf dff)];
sub supportedFormats { return @$FORMATS; }
sub samplerateLimit { return undef; }
1;
