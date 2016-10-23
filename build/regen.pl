use strict;
use warnings;
use autodie;

use B;
use Config;
use Config::Perl::V;

use Ouroboros;
use Ouroboros::Spec;
use Ouroboros::Library;
use File::Spec::Functions qw/catfile/;

require "build/lib/version.pl" or die;

use constant {
    EMBED_FNC_PATH => "build/embed.fnc",
    OURO_TXT_PATH => "ouroboros/libouroboros.txt",
    OUT_DIR => $ENV{OUT_DIR} // ".",

    PTHX_TYPE => "PerlThreadContext",

    STUB_TYPES => [
        "PerlInterpreter",
        "PerlIO",
        "SV",
        "AV",
        "HV",
        "HE",
        "GV",
        "CV",
        "OP",
        "IO",
        "BHK",
        "PERL_CONTEXT",
        "MAGIC",
        "MGVTBL",
        "PADLIST",
        "PADNAME",
        "PADNAMELIST",
        "HEK",
        "UNOP_AUX_item",
        "LOOP",
    ],

    TYPEMAP => {
        "ouroboros_stack_t" => "OuroborosStack",
        "ouroboros_xcpt_callback_t" => "extern fn(*mut ::std::os::raw::c_void)",

        "void" => "::std::os::raw::c_void",
        "int" => "::std::os::raw::c_int",
        "unsigned" => "::std::os::raw::c_uint",
        "unsigned int" => "::std::os::raw::c_uint",
        "char" => "::std::os::raw::c_char",
        "unsigned char" => "::std::os::raw::c_uchar",

        "bool" => "c_bool",
        "size_t" => "Size_t",
    },

    TYPESIZEMAP => {
        IV => {
            1 => "i8",
            2 => "i16",
            4 => "i32",
            8 => "i64",
        },
        UV => {
            1 => "u8",
            2 => "u16",
            4 => "u32",
            8 => "u64",
        },
        NV => {
            4 => "f32",
            8 => "f64",
        },
    },

    BLACKLIST => {
        "sv_nolocking" => "listed as part of public api, but not actually defined",
    },

    NO_CATCH => {
        "ouroboros_xcpt_try" => "captures perl croaks itself",
        "ouroboros_xcpt_rethrow" => "has to be able to die",
        "croak" => "has to be able to die",
    },

    # Map from names of variadic functions to names of known equivalents taking va_list.
    VARIADIC_IMPL => {
        "croak" => "vcroak",
    },

    RUST_TYPE => "Rust",
};

sub read_embed_fnc {
    my $embed_path = catfile(EMBED_FNC_PATH, current_apiver());
    my $opts = Config::Perl::V::myconfig()->{options};
    my @lines = read_file($embed_path);
    my @scope = (1);
    my @spec;
    while (defined ($_ = shift @lines)) {
        while (@lines && s/\\$/shift @lines/e) {}

        next if !$_ || /^:/;

        s/#\s*ifdef\s+(\w+)/#if defined($1)/;
        s/#\s*ifndef\s+(\w+)/#if !defined($1)/;

        if (my ($pp, $args) = /^#\s*(\w+)(.*)/) {
            if ($pp eq "if") {
                $args =~ s/defined\s*\([\w+]\)/\$opts->{$1}/;
                unshift @scope, eval $args && $scope[0];
            }
            elsif ($pp eq "endif") {
                die "unmatched #endif" if @scope < 2;
                shift @scope;
            }
            elsif ($pp eq "else") {
                $scope[0] = !$scope[0];
            }
            else {
                die "unknown directive $pp";
            }
            next;
        }

        next unless $scope[0];

        my ($flags, $type, $name, @args) = split /\s*\|\s*/;

        ($type, @args) = map s/^\s+//r =~ s/\s+$//r, ($type, @args);

        # perl volatile and nullability markers mean nothing here
        ($type, @args) = map s/\b(?:VOL|NN|NULLOK)\b\s*//gr, ($type, @args);

        next unless
            # public
            $flags =~ /A/ &&
            # documented
            $flags =~ /d/ &&
            # not a macro without c function
            !($flags =~ /m/ && $flags !~ /b/) &&
            # not experimental
            $flags !~ /M/ &&
            # not deprecated
            $flags !~ /D/;

        # va_list is useless in rust anyway
        next if grep /\bva_list\b/, $type, @args;

        push @spec, [ $flags, $type, $name, @args ];
    }

    return \@spec;
}

my $perl_spec = read_embed_fnc();
my $ouro_spec = \%Ouroboros::Spec::SPEC;

# Getters

sub map_type {
    my ($type) = @_;

    return $$type if ref $type eq RUST_TYPE;

    # working copy
    my $work = $type;

    # canonicalize const placement, "const int" is the same as "int const"
    $work =~ s/const\s+(\w+)/$1 const/;

    (my $base_type, $work) = $work =~ /^((?:unsigned )?\w+)\s*(.*)/
        or die "unparsable type '$type'";

    my $rust_type = TYPEMAP->{$base_type}
        or die "unknown type $base_type (was: $type)";

    my $lim = 100;
    while ($work && --$lim > 0) {
        my $mode = "mut";
        if ($work =~ s/^const\s*//) {
            $mode = "const";
        }
        if ($work =~ s/^\*\s*//) {
            $rust_type = "*$mode $rust_type";
        }
    }
    die "unparsable type '$type'" if !$lim;

    return $rust_type;
}

sub map_type_size {
    my ($base, $size) = @_;
    return TYPESIZEMAP->{$base}{$size} // die "$base size $size type is missing";
}

sub const_value {
    my $name = shift;
    my $getter = Ouroboros->can($name) // die "constant $name is not available";
    return $getter->();
}

# Rust syntax

sub ty {
    my $type = shift;
    return bless \$type, RUST_TYPE;
}

sub indent {
    map "    $_", @_;
}

sub mod {
    my ($name, @items) = @_;
    return (
        "pub mod $name {",
        indent(@items),
        "}",
    );
}

sub type {
    my ($name, $ty) = @_;

    TYPEMAP->{$name} = $name;

    return "pub type $name = $ty;";
}

sub extern {
    my ($abi, @items) = @_;
    return (
        "extern \"$abi\" {",
        indent(@items),
        "}",
    );
}

sub link_name {
    my ($name) = @_;
    return (qq!#[link_name="$name"]!);
}

sub _fn {
    my ($qual, $flags, $type, $name, @args) = @_;

    my $unnamed = $flags =~ /_/;
    my $genname = $flags =~ /!/;
    my $genpthx = $flags !~ /n/;

    my @formal;

    push @formal, ($unnamed ? "" : "my_perl: ") . "*mut PerlInterpreter" if $genpthx && $Config{usemultiplicity};

    my $argname = "arg0";
    foreach my $arg (@args) {
        if ($arg eq "...") {
            push @formal, $arg;
        }
        else {
            my ($type, $name);

            if ($genname || $unnamed) {
                $type = $arg;
                $name = undef;
            }
            else {
                ($type, $name) = $arg =~ /(.*)\b(\w+)/;
                $name =~ s/^/a_/ if $name =~ /^(?:type|fn|unsafe|let|loop|ref)$/;
            }

            $name = $argname++ if !$name && $genname;

            my $rs_type = map_type($type);

            if ($unnamed) {
                push @formal, $rs_type;
            } else {
                push @formal, sprintf "%s: %s", $name, $rs_type;
            }
        }
    }

    my $returns = $type eq "void" ? "" : " -> " . map_type($type);

    local $" = ", ";

    return "$qual fn $name(@formal)$returns";
}

sub fn {
    return _fn("pub", @_) . ";";
}

sub extern_fn {
    my ($type, @args) = @_;

    return _fn('extern "C"', "_", $type, "", @args);
}

sub perl_fn {
    my ($flags, $type, $name, @args) = @_;

    my $link_name = $flags =~ /[pb]/ ? "Perl_$name" : $name;

    return (
        link_name($link_name),
        fn($flags, $type, $name, @args),
    );
}

sub ouro_flags {
    my $fn = shift;
    my $flags = "!";
    $flags .= "n" if $fn->{tags}{no_pthx};
    return $flags;
}

sub ouro_fn {
    my $fn = shift;

    my @args = @{$fn->{params}};
    unshift @args, "$fn->{type} *" if $fn->{type} ne "void";

    return (
        link_name("perl_sys_$fn->{name}"),
        fn(ouro_flags($fn), "int", $fn->{name}, @args));
}

sub wrap_fn {
    my ($flags, $type, $name, @args) = @_;

    return (
        link_name("perl_sys_$name"),
        fn($flags, "int", $name, @args),
    );
}

sub const {
    my ($name, $value) = @_;
    return "pub const $name: IV = $value;";
}

sub struct {
    my ($name, @fields) = @_;

    my @fields_rs;
    while (my ($name, $type) = splice @fields, 0, 2) {
        push @fields_rs, sprintf "%s: %s,", $name, map_type($type);
    }

    return (
        "#[repr(C)]",
        "pub struct $name {",
        indent(@fields_rs),
        "}"
    );
}

sub enum {
    my ($name, @items) = @_;
    die "non-empty enums are not supported yet" if @items;

    TYPEMAP->{$name} = $name;

    return "pub enum $name {}";
}


# Output blocks

sub perl_types {
    my $c = \%Config::Config;
    my $os = \%Ouroboros::SIZE_OF;

    my $pthx = $c->{usemultiplicity}
        ? type(PTHX_TYPE, "*mut PerlInterpreter")
        : type(PTHX_TYPE, "()");

    return (
        map(enum($_), @{STUB_TYPES()}),

        $pthx,

        type("IV", map_type_size("IV", $c->{ivsize})),
        type("UV", map_type_size("UV", $c->{uvsize})),
        type("NV", map_type_size("NV", $c->{nvsize})),

        type("I8", map_type_size("IV", $c->{i8size})),
        type("U8", map_type_size("UV", $c->{u8size})),
        type("I16", map_type_size("IV", $c->{i16size})),
        type("U16", map_type_size("UV", $c->{u16size})),
        type("I32", map_type_size("IV", $c->{i32size})),
        type("U32", map_type_size("UV", $c->{u32size})),

        # assumes that these three types have the same size
        type("Size_t", map_type_size("UV", $c->{sizesize})),
        type("SSize_t", map_type_size("UV", $c->{sizesize})),
        type("STRLEN", map_type_size("UV", $c->{sizesize})),

        type("c_bool", map_type_size("UV", $os->{bool})),
        type("svtype", map_type_size("UV", $os->{svtype})),
        type("PADOFFSET", map_type_size("UV", $os->{PADOFFSET})),
        type("Optype", map_type_size("UV", $os->{Optype})),

        type("XSINIT_t", extern_fn("void")),
        type("SVCOMPARE_t", extern_fn("I32", "SV*", "SV*")),
        type("XSUBADDR_t", extern_fn("void", "CV*")),
        type("Perl_call_checker", extern_fn("OP*", "OP*", "GV*", "GV*")),
        type("Perl_check_t", extern_fn("OP*", "OP*")),

        struct("OuroborosStack", _data => ty sprintf("[u8; %d]", $os->{"ouroboros_stack_t"})),
    );
}

sub perl_funcs {
    return extern("C",
        map(perl_fn(@$_), sort { $a->[2] cmp $b->[2] } @$perl_spec));
}

sub ouro_funcs {
    return extern("C",
        map(ouro_fn($_), sort { $a->{name} cmp $b->{name} } @{$ouro_spec->{fn}}));
}

sub wrap_funcs {
    my ($wrapper_defs) = @_;
    return extern("C",
        map(wrap_fn(@$_), sort { $a->[2] cmp $b->[2] } @$wrapper_defs));
}

sub perl_consts {
    map(const($_, eval "B::$_"), grep /^SV(?!t_)/ || /^G_/, @B::EXPORT_OK);
}

sub ouro_consts {
    map(const($_, const_value($_)), @Ouroboros::CONSTS);
}

sub xcpt_wrapper {
    my ($flags, $type, $name, @params) = @_;

    if (my $reason = BLACKLIST->{$name}) {
        warn "skipping blacklisted '$name': $reason\n";
        return ();
    }

    my $impl = $name;

    my (@args, @sign);
    my (@va_list, @va_start, @va_end);
    foreach my $param (@params) {
        if ($param eq "...") {
            $impl = VARIADIC_IMPL->{$name};
            if (!$impl) {
                warn "skipping variadic function '$name': va_list equivalent is not known";
                return ();
            }

            my $va_name = "ap";
            $va_name++ while (grep $_ eq $va_name, @args);

            @va_list = "va_list $va_name;";
            @va_start = "va_start($va_name, $args[-1]);";
            @va_end = "va_end($va_name);";

            push @sign, "...";
            push @args, "&$va_name";
        }
        else {
            my ($type, $name) = $param =~ /(.*)\b(\w+)/;
            push @sign, "$type $name";
            push @args, $name;
        }
    }

    my $store = "";
    if ($type ne "void") {
        unshift @sign, "$type* RETVAL";
        $store = "*RETVAL = ";
    }

    local $SIG{__WARN__} = sub { die "$type $name @params: @_" };

    my $wrapper_name = "perl_sys_$name";

    my $genpthx = $flags !~ /n/ && $Config{usemultiplicity};
    my $genperl = ($flags =~ /b/ || $flags =~ /o/) && $flags !~ /m/ && $flags =~ /p/;
    my $genouro = $flags =~ /!/;

    if ($genperl) {
        $impl = "Perl_$impl";
    }

    my @pthx;
    if ($genpthx) {
        @pthx = ("pTHX");
        unshift @args, "aTHX" if ($genperl || $genouro);
    }

    my (@jmpenv_push, @jmpenv_pop);
    unless ($flags =~ /n/ || NO_CATCH->{$name}) {
        @jmpenv_push = (
            "dJMPENV;",
            "JMPENV_PUSH(rc);",
        );
        @jmpenv_pop = (
            "JMPENV_POP;",
        );
    }

    die "$flags $name\n" if !$genouro && $name =~ /ouroboros/;

    local $" = ", ";

    return {
        source => [
            "int $wrapper_name(@{[@pthx, @sign]}) {",
            indent(
                "int rc = 0;",
                @va_list,
                @va_start,
                @jmpenv_push,
                "if (rc == 0) { $store$impl(@args); }",
                @jmpenv_pop,
                @va_end,
                "return rc;",
            ),
            "}",
        ],
        def => [ "", "int", $name, @sign ],
    };
}

sub xcpt_wrapper_ouro {
    my $fn = shift;
    return () if $fn->{name} eq "ouroboros_xcpt_try";
    my $pn = "a";
    my @params = map { $_ . " " . $pn++ } @{$fn->{params}};
    xcpt_wrapper(ouro_flags($fn), $fn->{type}, $fn->{name}, @params);
}

sub perl_wrappers {
    map(xcpt_wrapper(@$_), @$perl_spec);
}

sub ouro_wrappers {
    map(xcpt_wrapper_ouro($_), @{$ouro_spec->{fn}});
}

sub build_wrappers {
    my @perl_wrappers = perl_wrappers();
    my @ouro_wrappers = ouro_wrappers();


    my $src = [
        "/* Generated for Perl $Config::Config{version} */",
        q{#define PERL_NO_GET_CONTEXT},
        q{#include "EXTERN.h"},
        q{#include "perl.h"},
        q{#include "XSUB.h"},
        q{#define OUROBOROS_STATIC static},
        map(qq{#include "$_"}, Ouroboros::Library::c_header()),
        "",
        map(@{$_->{source}}, @perl_wrappers, @ouro_wrappers),
        "",
        map(qq{#include "$_"}, Ouroboros::Library::c_source()),
    ];

    my $defs = [ map $_->{def}, @perl_wrappers, @ouro_wrappers ];

    return ($src, $defs);
}

sub build_bindings {
    my ($wrapper_defs) = @_;
    return (
        "/* Generated for Perl $Config::Config{version} */",
        mod("types",
            "#![allow(non_camel_case_types)]",
            perl_types()),
        "",
        "#[macro_use]",
        mod("fn_bindings",
            "use super::types::*;",
            perl_funcs(),
            ouro_funcs()),
        "",
        mod("fn_wrappers",
            "use super::types::*;",
            wrap_funcs($wrapper_defs)),
        "",
        mod("consts",
            "#![allow(non_upper_case_globals)]",
            "use super::types::*;",
            perl_consts(),
            ouro_consts()),
    );
}

#

sub read_file {
    my ($name, %opts) = @_;
    open my $fh, "<", $name;
    my @lines = <$fh>;
    close $fh;
    chomp foreach @lines;
    return @lines;
}

sub write_file {
    my ($name, @lines) = @_;
    open my $fh, ">", catfile(OUT_DIR, $name);
    $fh->print(map "$_\n", @lines);
    close $fh;
}

my ($wrapper_src, $wrapper_defs) = build_wrappers();
write_file("perl_sys.c", @$wrapper_src);
write_file("perl_sys.rs", build_bindings($wrapper_defs));
