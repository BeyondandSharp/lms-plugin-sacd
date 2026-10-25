package Slim::Music::Info;
use strict; use warnings;
sub isFileURL { return $_[0] =~ m{^file://} ? 1 : 0; }
1;
