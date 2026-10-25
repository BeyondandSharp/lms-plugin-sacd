package Slim::Player::TranscodingHelper;
use strict; use warnings;
our %commandTable;
our %capabilities;
our @CALLS;
sub getConvertCommand2 {
    my @a = @_;
    push @CALLS, [ @a ];
    return { command => 'stub', profile => 'stub', streamformat => 'stub' };
}
1;
