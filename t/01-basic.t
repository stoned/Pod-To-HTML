use Test;
use Pod::To::HTML;
plan 3;
my $r;

# XXX Need a module to walk HTML trees

=begin foo
=end foo

$r = node2html $=pod[0];
ok $r ~~ ms/'<section>' '<h1>' foo '</h1>' '</section>' /;

=begin foo
some text
=end foo

$r = node2html $=pod[1];
ok $r ~~ ms/'<section>' '<h1>' foo '</h1>' '<p>' some text '</p>' '</section>'/;

=head1 Talking about Perl 6

say "Talking about Perl 6".comb.map: *.ord;
say twrap("Talking about Perl 6".Str).comb.map: *.ord;
say $=pod[2].perl;
say $=pod[2].contents[0].contents[0].comb.map: *.ord;
$r = node2html $=pod[2];
nok $r ~~ ms/Perl 6/;

sub twrap($text is copy, :$wrap=75 ) {
    $text ~~ s:g/(. ** {$wrap} <[\s]>*)\s+/$0\n/;
    $text
}
