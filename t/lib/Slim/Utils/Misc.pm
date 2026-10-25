package Slim::Utils::Misc;
use strict; use warnings;
use Exporter 'import';
our @EXPORT = qw(findbin pathFromFileURL);
sub findbin {
    my ($name)=@_;
    return $name if $name =~ m{^/} && -x $name;
    for my $d (split /:/, $ENV{PATH}||'') { return "$d/$name" if -x "$d/$name"; }
    return undef;
}
sub pathFromFileURL { my ($u)=@_; $u =~ s/^file:\/\///; $u =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge; return $u; }
1;
