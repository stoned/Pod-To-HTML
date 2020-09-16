unit module Pod::To::HTML;

use URI::Escape;
use Template::Mustache;
use Pod::Load;

# the Rakudo compiler expects there to be a render method with a Pod::To::<name> invocant
## when --doc=name is used. Then the render method is called with a pod tree.
## The following adds a Pod::To::HTML class and the method to call the subs in the module.
class Pod::To::HTML {
    method render($pod) { &render($pod) }
}

multi render(Any $pod, Str :$title, Str :$subtitle, Str :$lang,
             Str :$template = Str, Str :$main-template-path = '', *%template-vars) {
    pod2html($pod, :$title, :$subtitle, :$lang, :$template, :$main-template-path, |%template-vars)
}
multi render(Pod::Block $file, *%nameds) is export { nextsame }
multi render(Array $file, *%nameds) is export { nextsame }
multi render($file where Str|IO::Path, *%nameds) is export { nextwith((load($file)), |%nameds) }

# FIXME: this code's a horrible mess. It'd be really helpful to have a module providing a generic
# way to walk a Pod tree and invoke callbacks on each node, that would reduce the multispaghetti at
# the bottom to something much more readable.

my &url = {$_};
my @indexes;
my @body;
my @footnotes;
my %metadata;
my %crossrefs;

# see <https://docs.perl6.org/language/traps#Constants_are_Compile_Time>
my  $debug := %*ENV<P6DOC_debug>;

sub debug(Callable $c) { $c() if $debug; }

sub escape_html(Str $str --> Str ) {
  return $str unless ( $str ~~ /<[ & < > " ' {   ]>/ ) or ( $str ~~ / ' ' / );
  $str.trans( [ q{&},     q{<},    q{>},    q{"},      q{'},     q{ }     ] =>
                [ q{&amp;}, q{&lt;}, q{&gt;}, q{&quot;}, q{&#39;}, q{&nbsp;}]);
}

sub unescape_html(Str $str --> Str ) {
    $str.trans( [ rx{'&amp;'}, rx{'&lt;'}, rx{'&gt;'}, rx{'&quot;'}, rx{'&#39;'} ] =>
                [ q{&},        q{<},       q{>},       q{"},         q{'}        ] );
}

sub escape_id ($id) {
    $id.trim.subst(/\s+/, '_', :g)
      .subst('"', '&quot;', :g)
      .subst('&nbsp;', '_', :g)
      .subst('&#39;', "'", :g);
}

multi visit(Nil, |a) {
    debug { note colored("visit called for Nil", "bold") }
}

multi visit($root, :&pre, :&post, :&assemble = -> *% { Nil }) {
    debug { note colored("visit called for ", "bold") ~ $root.perl }
    my ($pre, $post);
    $pre = pre($root) if defined &pre;

    my @content = $root.?contents.map: {visit $_, :&pre, :&post, :&assemble};
    $post = post($root, :@content) if defined &post;

    return assemble(:$pre, :$post, :@content, :node($root));
}

#try require Term::ANSIColor <&colored>;
#if &colored.defined {
# &colored = -> $t, $c { $t };
#}

sub colored($text, $how) {
    $text
}

class Pod::List is Pod::Block { };
class Pod::DefnList is Pod::Block { };
BEGIN { if ::('Pod::Defn') ~~ Failure { CORE::Pod::<Defn> := class {} } }

sub assemble-list-items(:@content, :$node, *% ) {
    my @newcont;
    my $foundone = False;
    my $everwarn = False;

    my $atlevel = 0;
    my @pushalias;

    my sub oodwarn($got, $want) {
        unless $everwarn {
            warn "=item$got without preceding =item$want found!";
            $everwarn = True;
        }
    }

    for @content {
        when Pod::Item {
            $foundone = True;

            # here we deal with @newcont being empty (first list), or with the
            # last element not being a list (new list)
            unless +@newcont && @newcont[*-1] ~~ Pod::List {
                @newcont.push(Pod::List.new());
                if $_.level > 1 {
                    oodwarn($_.level, 1);
                }
            }

            # only bother doing the binding business if we're at a different
            # level than previous items
            if $_.level != $atlevel {
                # guaranteed to be bound to a Pod::List (see above 'unless')
                @pushalias := @newcont[*-1].contents;

                for 2..($_.level) -> $L {
                    unless +@pushalias && @pushalias[*-1] ~~ Pod::List {
                        @pushalias.push(Pod::List.new());
                        if +@pushalias == 1 { # we had to push a sublist to a list with no =items
                            oodwarn($OUTER::_.level, $L);
                        }
                    }
                    @pushalias := @pushalias[*-1].contents;
                }

                $atlevel = $_.level;
            }

            @pushalias.push($_);
        }
        # This is simpler than lists because we don't need to
        # list
        when Pod::Defn {
            $foundone = True;
            unless +@newcont && @newcont[*-1] ~~ Pod::DefnList {
                @newcont.push(Pod::DefnList.new());
            }
            @newcont[*-1].contents.push($_);
        }

        default {
            @newcont.push($_);
            $atlevel = 0;
        }
    }

    return $foundone ?? $node.clone(contents => @newcont) !! $node;
}

sub retrieve-templates( $template-path, $main-template-path --> List) {
    sub get-partials( $template-path --> Hash ) {
        my $partials-dir = 'partials';
        my %partials;
        for dir($template-path.IO.add($partials-dir)) -> $partial {
            %partials{$partial.basename.subst(/\.mustache/, '')} = $partial.IO.slurp;
        }
        return %partials;
    }

    my $template-file = %?RESOURCES<templates/main.mustache>;
    my %partials;

    with $template-path {
         if  "$template-path/main.mustache".IO ~~ :f {
            $template-file = $template-path.IO.add('main.mustache').IO;

            if $template-path.IO.add('partials') ~~ :d {
                %partials = get-partials($template-path);
            }
         }
         else {
            note "$template-path does not contain required templates. Using default.";
        }
    }

    if $main-template-path {
        $template-file = $main-template-path.IO;
    }

    return $template-file, %partials;
}

# Converts a Pod tree to a HTML document using templates
my $stache = Template::Mustache.new;
sub pod2html(
    $pod,
    :&url = -> $url { $url },
    :$title,
    :$subtitle,
    :$lang,
    :templates(:$template) = Str,
    :$main-template-path,
    *%template-vars,
    --> Str
) is export {

    (@indexes, @body, @footnotes) = ();
    # Keep count of how many footnotes we've output.
    my Int $*done-notes = 0;
    &OUTER::url = &url;
    debug { note colored("About to call node2html ", "bold") ~ $pod.perl };
    @body.push: node2html($pod.map: { visit $_, :assemble(&assemble-list-items) });

    # sensible css default
    my $default-style = %?RESOURCES<css/github.css>.IO.slurp;

    # title and subtitle picked from Pod document can be overriden
    # with provided ones via the subroutines.
    my $title-html    = $title // %metadata<title> // '';
    my $subtitle-html = $subtitle // %metadata<subtitle> // '';
    my $lang-html     = $lang // %metadata<lang> // 'en';

    my %context = %(
        :@body,
        # documentable template vars
        :title($title-html),
        :subtitle($subtitle-html),
        :toc(do-toc($pod)),
        :lang($lang-html),
        :footnotes(do-footnotes),
        # probably documentable
        :$default-style,
        # user should be aware that semantic blocks are made available to the Mustache template.
        |%metadata,
        # user can supply additional template variables for the Mustache template.
        |%template-vars,
    );

    # get 'main.mustache' file (and possible its partials) under template path.
    my ($template-file, %partials) = retrieve-templates($template, $main-template-path);
    my $content = $template-file.IO.slurp;
    
    # reset for next execution
    %metadata = %();

    return $stache.render($content, %context, :from[%partials], :literal);
}

# Returns accumulated metadata. In this sense, metadata is any
# semantic block found in the Pod document.
#sub do-metadata( --> Hash ) {
#    return +%metadata
#    ?? %metadata.map({ $^p.key => node2text($^p.value) }).hash
#    !! %();
#}

# Turns accumulated headings into a nested-C«<ol>» table of contents
sub do-toc($pod --> Str ) {
    my @levels is default(0) = 0;

    my proto sub find-headings($node, :$inside-heading){*}

    multi sub find-headings(Str $s is raw, :$inside-heading){
      $inside-heading ?? $s.trim.&escape_html !! ''
    }

    multi sub find-headings(Pod::FormattingCode $node is raw where *.type eq 'C', :$inside-heading){
      my $html = $node.contents.map(*.&find-headings(:$inside-heading));
      $inside-heading ?? qq[<code class="pod-code-inline">{$html}</code>] !! ''
    }

    multi sub find-headings(Pod::Heading $node is raw, :$inside-heading) {
      @levels.splice($node.level) if $node.level < +@levels;
      @levels[$node.level-1]++;
        my $level-hierarchy = @levels.join('.'); # e.g. §4.2.12
        my $text = $node.contents.map(*.&find-headings(inside-heading => True));
        my $link = escape_id(node2text($node.contents));
        qq[<tr class="toc-level-{$node.level}"><td class="toc-number">{$level-hierarchy}</td><td class="toc-text"><a href="#$link">{$text}</a></td></tr>\n];
    }

    multi sub find-headings(Positional \list, :$inside-heading){
        list.map(*.&find-headings(:$inside-heading))
    }

    multi sub find-headings(Pod::Block $node is raw, :$inside-heading){
        $node.contents.map(*.&find-headings(:$inside-heading))
    }

    multi sub find-headings(Pod::Config $node, :$inside-heading){
        ''
    }

    multi sub find-headings(Pod::Raw $node is raw, :$inside-heading){
        $node.contents.map(*.&find-headings(:$inside-heading))
    }

    my $html = find-headings($pod);
    $html.trim ??
        qq:to/EOH/
        <nav class="indexgroup">
        <table id="TOC">
        <caption><h2 id="TOC_Title">Table of Contents</h2></caption>
        {$html}
        </table>
        </nav>
        EOH
    !! ''
}

# Flushes accumulated footnotes since last call. The idea here is that we can stick calls to this
# before each C«</section>» tag (once we have those per-header) and have notes that are visually
# and semantically attached to the section.
sub do-footnotes(  --> Str ) {
    return '' unless @footnotes;

    my Int $current-note = $*done-notes + 1;
    my $notes = @footnotes.kv.map(-> $k, $v {
        my $num = $k + $current-note;
        qq{<li><a href="#fn-ref-$num" id="fn-$num">[↑]</a> $v </li>\n}
    }).join;

    $*done-notes += @footnotes;
    @footnotes = ();

    return qq[<aside><ol start="$current-note">\n]
         ~ $notes
         ~ qq[</ol></aside>\n];
}

# block level or below
proto sub node2html(| --> Str ) is export {*}
multi sub node2html($node) {
    debug { note colored("Generic node2html called for ", "bold") ~ $node.perl };
    return node2inline($node);
}

multi sub node2html(Pod::Block::Declarator $node) {
    given $node.WHEREFORE {
        when Routine {
            "<article>\n"
                ~ '<code class="pod-code-inline">'
                    ~ node2text($node.WHEREFORE.name ~ $node.WHEREFORE.signature.perl)
                ~ "</code>:\n"
                ~ node2html($node.contents)
            ~ "\n</article>\n";
        }
        default {
            debug { note "I don't know what {$node.WHEREFORE.WHAT.perl} is. Assuming class..." };
        "<h1>"~ node2html([$node.WHEREFORE.perl, q{: }, $node.contents])~ "</h1>";
        }
    }
}

multi sub node2html(Pod::Block::Code $node) {
    debug { note colored("Code node2html called for ", "bold") ~ $node.gist };
    if %*POD2HTML-CALLBACKS and %*POD2HTML-CALLBACKS<code> -> &cb {
        return cb :$node, default => sub ($node) {
            return '<pre class="pod-block-code">' ~ node2inline($node.contents) ~ "</pre>\n"
        }
    }
    else  {
        return '<pre class="pod-block-code">' ~ node2inline($node.contents) ~ "</pre>\n"
    }

}

multi sub node2html(Pod::Block::Comment $node) {
    debug { note colored("Comment node2html called for ", "bold") ~ $node.gist };
    return '';
}

multi sub node2html(Pod::Block::Named $node) {
    debug { note colored("Named Block node2html called for ", "bold") ~ $node.gist };
    given $node.name {
        when 'config' { return '' }
        when 'nested' {
            return qq{<div class="nested">\n} ~ node2html($node.contents) ~ qq{\n</div>\n};
        }
        when 'output' { return qq[<pre class="pod-block-named-outout">\n] ~ node2inline($node.contents) ~ "</pre>\n"; }
        when 'pod'  {
            return qq[<span class="{$node.config<class>}">\n{node2html($node.contents)}</span>\n]
                if $node.config<class>;
            return node2html($node.contents);
        }
        when 'para' { return node2html($node.contents[0]); }
        when 'Image' {
            my $url;
            if $node.contents == 1 {
                my $n = $node.contents[0];
                if $n ~~ Str {
                    $url = $n;
                }
                elsif ($n ~~ Pod::Block::Para) &&  $n.contents == 1 {
                    $url = $n.contents[0] if $n.contents[0] ~~ Str;
                }
            }
            unless $url.defined {
                die "Found an Image block, but don't know how to extract the image URL :(";
            }
            return qq[<img src="$url" />];
        }
        when 'Xhtml' | 'Html' {
            unescape_html node2rawhtml $node.contents
        }
        default {
            # A named block, specifically a semantic block.
            # Semantic blocks (https://docs.raku.org/language/pod#Semantic_blocks)
            # are collected and supplied to templates as a poor man's YAML
            # metadata :-).
            if [and]
            $node.name.match(/^<[A..Z]>+$/),
            $node.contents.elems == 1,
            $node.contents.head ~~ Pod::Block::Para
            {
                %metadata{ $node.name.lc } = node2text($node.contents);
                return '';
            }
            # any other named block
            else {
                return '<section>'
                    ~ "<h1>{$node.name}</h1>\n"
                    ~ node2html($node.contents)
                    ~ "</section>\n";
            }
        }
    }
}

sub node2rawhtml(Positional $node) {
    return $node.map({ node2rawtext $_ }).join
}

multi sub node2html(Pod::Block::Para $node) {
    debug { note colored("Para node2html called for ", "bold") ~ $node.gist };
    return '<p>' ~ node2inline($node.contents) ~ "</p>\n";
}

multi sub node2html(Pod::Block::Table $node) {
    debug { note colored("Table node2html called for ", "bold") ~ $node.gist };
    my @r = $node.config<class>??'<table class="pod-table '~$node.config<class>~'">'!!'<table class="pod-table">';

    if $node.caption -> $c {
        @r.push("<caption>{node2inline($c)}</caption>");
    }

    if $node.headers {
        @r.push(
            '<thead><tr>',
            $node.headers.map(-> $cell {
                "<th>{node2html($cell)}</th>"
            }),
            '</tr></thead>'
        );
    }

    @r.push(
        '<tbody>',
        $node.contents.map(-> $line {
            '<tr>',
            $line.list.map(-> $cell {
                "<td>{node2html($cell)}</td>"
            }),
            '</tr>'
        }),
        '</tbody>',
        '</table>'
    );

    return @r.join("\n");
}

multi sub node2html(Pod::Config $node) {
    debug { note colored("Config node2html called for ", "bold") ~ $node.perl };
    return '';
}

multi sub node2html(Pod::DefnList $node ) {
    return "<dl>\n" ~ node2html($node.contents) ~ "\n</dl>\n";

}
multi sub node2html(Pod::Defn $node) {

                    "<dt>" ~ node2html($node.term) ~ "</dt>\n" ~
                    "<dd>" ~ node2html($node.contents) ~ "</dd>\n";
}

# TODO: would like some way to wrap these and the following content in a <section>; this might be
# the same way we get lists working...
multi sub node2html(Pod::Heading $node) {
    debug { note colored("Heading node2html called for ", "bold") ~ $node.gist };
    my $lvl = min($node.level, 6); #= HTML only has 6 levels of numbered headings
    my %escaped = (
        id => escape_id(node2rawtext($node.contents)),
        html => node2inline($node.contents),
    );

    %escaped<uri> = uri_escape %escaped<id>;

    @indexes.push: Pair.new(key => $lvl, value => %escaped);

    my $content;
    if ( %escaped<html> ~~ m{href .+ \<\/a\>} ) {
      $content =  %escaped<html>;
    } else {
      $content = qq[<a class="u" href="#___top" title="go to top of document">]
    ~ %escaped<html>
    ~ qq[</a>];
    }

    return sprintf('<h%d id="%s">', $lvl, %escaped<id>)
                ~ $content ~ qq[</h{$lvl}>\n];
}

# FIXME
multi sub node2html(Pod::List $node) {
    return '<ul>' ~ node2html($node.contents) ~ "</ul>\n";
}
multi sub node2html(Pod::Item $node) {
    debug { note colored("List Item node2html called for ", "bold") ~ $node.gist };
    return '<li>' ~ node2html($node.contents) ~ "</li>\n";
}

multi sub node2html(Positional $node) {
  debug { note colored("Positional node2html called for ", "bold") ~ $node.gist };
  return $node.map({ node2html($_) }).join
}

multi sub node2html(Str $node) {
    return escape_html($node);
}


# inline level or below
multi sub node2inline($node --> Str ) {
  debug { note colored("missing a node2inline multi for ", "bold") ~ $node.gist };
  return node2text($node);
}

multi sub node2inline(Pod::Block::Para $node --> Str ) {
  return node2inline($node.contents);
}

multi sub node2inline(Pod::FormattingCode $node --> Str ) {
    my %basic-html = (
        B => 'strong',  #= Basis
        C => 'code',    #= Code
        I => 'em',      #= Important
        K => 'kbd',     #= Keyboard
        R => 'var',     #= Replaceable
        T => 'samp',    #= Terminal
        U => 'u',       #= Unusual (css: text-decoration-line: underline)
    );

    given $node.type {
        when any(%basic-html.keys) {
            return q{<} ~ %basic-html{$_} ~ q{>}
                ~ node2inline($node.contents)
                ~ q{</} ~ %basic-html{$_} ~ q{>};
        }

        # Escape
        when 'E' {
            return $node.meta.map({
                when Int { "&#$_;" }
                when Str { "&$_;"  }
            }).join;
        }

        # Note
        when 'N' {
            @footnotes.push(node2inline($node.contents));

            my $id = +@footnotes;
            return qq{<a href="#fn-$id" id="fn-ref-$id">[$id]</a>};
        }

        # Links
        when 'L' {
                  my $text = node2inline($node.contents);
                  my $url  = $node.meta[0] || node2text($node.contents);
                  
                  if $text ~~ /^'#'/ {
                      # if we have an internal-only link, strip the # from the text.
                      $text = $/.postmatch
                  }
                  if ! $text ~~ /^\?/ {
                      $url = unescape_html($url);
                  }

                  if $url ~~ /^'#'/ {
                      $url = '#' ~ uri_escape( escape_id($/.postmatch) )
                  }

                  return qq[<a href="{url($url)}">{$text}</a>]
        }

        # zero-width comment
        when 'Z' {
            return '';
        }

        when 'D' {
            # TODO memorise these definitions (in $node.meta) and display them properly
            my $text = node2inline($node.contents);
            return qq[<defn>{$text}</defn>]
        }

        when 'X' {
            multi sub recurse-until-str(Str:D $s){ $s }
            multi sub recurse-until-str(Pod::Block $n){ $n.contents>>.&recurse-until-str().join }

            my $index-text = recurse-until-str($node).join;
            my @indices = $node.meta;
            my $index-name-attr = qq[index-entry{@indices ?? '-' !! ''}{@indices.join('-')}{$index-text ?? '-' !! ''}$index-text].subst('_', '__', :g).subst(' ', '_', :g);
            $index-name-attr = url($index-name-attr).subst(/^\//, '');
            my $text = node2inline($node.contents);
            %crossrefs{$_} = $text for @indices;

            return qq[<a name="$index-name-attr"><span class="index-entry">$text\</span></a>] if $text;
            return qq[<a name="$index-name-attr"></a>];
        }

        # Stuff I haven't figured out yet
        default {
            debug { note colored("missing handling for a formatting code of type ", "red") ~ $node.type }
            return qq{<kbd class="pod2html-todo">$node.type()&lt;}
                    ~ node2inline($node.contents)
                    ~ q{&gt;</kbd>};
        }
    }
}

  multi sub node2inline(Positional $node --> Str ) {
    return $node.map({ node2inline($_) }).join;
}

  multi sub node2inline(Str $node --> Str ) {
    return escape_html($node);
}


# HTML-escaped text
multi sub node2text($node --> Str ) {
    debug { note colored("missing a node2text multi for ", "red") ~ $node.perl };
    return escape_html(node2rawtext($node));
}

multi sub node2text(Pod::Block::Para $node --> Str ) {
    return node2text($node.contents);
}

multi sub node2text(Pod::Raw $node --> Str ) {
    my $t = $node.target;
    if $t && lc($t) eq 'html' {
        $node.contents.join
    }
    else {
        '';
    }
}

# FIXME: a lot of these multis are identical except the function name used...
#        there has to be a better way to write this?
multi sub node2text(Positional $node --> Str ) {
    return $node.map({ node2text($_) }).join;
}

multi sub node2text(Str $node --> Str ) {
    return escape_html($node);
}

# plain, unescaped text
multi sub node2rawtext($node --> Str ) {
    debug { note colored("Generic node2rawtext called with ", "red") ~ $node.perl };
    return $node.Str;
}

multi sub node2rawtext(Pod::Block $node --> Str ) {
    debug { note colored("node2rawtext called for ", "bold") ~ $node.gist };
    return node2rawtext($node.contents);
}

multi sub node2rawtext(Positional $node --> Str ) {
    return $node.map({ node2rawtext($_) }).join;
}

multi sub node2rawtext(Str $node --> Str ) {
    return $node;
}

# vim: expandtab shiftwidth=4 ft=perl6