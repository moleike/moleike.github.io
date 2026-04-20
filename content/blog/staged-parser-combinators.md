---
title: "Staged Parser Combinators in Scala: Have Your Cake and Eat It (Too)"
date: 2026-04-20
draft: false
discussion_id: 26
tags:
  - programming
  - performance
  - scala
  - parsing
  - macros
  - multi-stage programming
---

Parser combinators have a reputation of poor performance---worst-case
exponential time---and deemed good for prototyping but not for production. Or so
the story goes. While techniques like Packrat parsing or static analysis offer
linear-time guarantees by addressing naive backtracking, they come with their
own trade-offs.

In this post, I want to explore an optimization route that complements the
others: avoiding the performance penalty of abstraction.

By leaning into Scala 3's metaprogramming capabilities, our combinators combine
_code fragments_. By moving to a _staged_ continuation-passing style (CPS)
encoding, we make the control flow explicit and continuations are fully
evaluated at compile time. Results show that a staged parser runs ~50% faster
than a handwritten recursive descent parser and over 25x faster than a
non-staged version. Interestingly, this approach is deeply rooted in partial
evaluation history, closely mirroring the [First Futamura
Projection](https://arxiv.org/abs/1611.09906).

The code used throughout the post is available in [this gist][gist]. The main
combinator library plus some example parsers is just ~230 sloc, while a
non-staged combinator library implemented with Cats is 150 sloc.

[gist]: https://gist.github.com/moleike/6fa86a3907a9d42dff349a0b53c4e809

## Multi-stage programming (MSP)

One of the novel features of Scala 3 was the redesign of metaprogramming,
combining macros and staging. Multi-stage programming formalizes the idea of
evaluating programs in distinct temporal phases or _stages_. By dividing program
evaluation into stages we decide _when_ computation happens---which in practical
terms mean either at compile-time or runtime. To move across stages _safely_
Scala enforces a strict phase distinction with _quotations_:

* Level **0**: normal code execution.
* Level +1: code inside a quote `'{..}` captures syntax---typed ASTs---deferring
  execution to the next phase.
* Level -1: code inside a splice `${..}` drops down a level to be evaluated
  immediately.
  
Staging a program `p` of type `A` using a quote results in an unevaluated
expression of type `Expr[A]`. Conversely, splicing a staged expression `e` of
type `Expr[A]` evaluates it into code of type `A`. Importantly, if a quote is
well typed, then the generated code is well typed. Because the compiler tracks
quotation levels (phase consistency), you can't accidentally use a runtime
variable at compile time, so if your program compiles, it's _well-staged_. Let's
see an example:

```scala
def id[A: Type](value: Expr[A])(using Quotes): Expr[A] = 
  '{ val a: A = $value; a }
```

This `id` function is a _code generator_: it takes an AST and generates another
one. Scala requires both a given `Quotes` to create quoted code `'{..}`, and the
type class `Type[A]` to carry type information across stages.

```scala
val result = id('{ 3 + 5 })
```

When the compiler evaluates the code, it uses the `Type[Int]` to correctly type value `a`

```scala
'{ val a: Int = $value; a }
```

The compiler sees `$value` and pastes the AST `'{ 3 + 5 }'`:

```scala
'{ val a: Int = ${ '{ 3 + 5 } }; a }
```

Since quotes and splices shift exactly one level in opposite directions, they
exhibit a cancellation property: `${ '{e} } = e` and `'{ ${e} } = e`: 

```scala
'{ val a: Int = 3 + 5; a }
```


Where do macros fit in? In Scala 3, a macro is simply an inline function
containing a _top-level splice_ (`${..}`). The inline keyword forces
compile-time expansion, while the splice drops down a level to evaluate the
staged computation, injecting the resulting generated code into the program.

```scala
inline def id[A](inline value: A): A = ${ id('{ value }) }
```

Instead of writing one massive, monolithic macro (which is how code generation
usually feels), you build your final program by composing functions.

To see how this all comes together, we are going to stage a parser combinator
library. The key insight is that while a library is generic, a specific grammar
is typically known the moment a user compiles their program. By evaluating the
static grammar at compile-time and quoting only the logic that depends on
runtime input, we can transform a high-level recursive DSL into a specialized
parser that eliminates the traditional overhead of abstraction in combinator
libraries.

(Note: this was a rather rushed intro to multi-stage programming in Scala,
checking out the official language reference [here][macros] is a great next
step.)

[macros]: https://docs.scala-lang.org/scala3/reference/metaprogramming/macros.html

## Parser combinators

Parser combinators are used to derive recursive descent parsers that are very
similar to the grammar of a language, and translating a grammar into a program
tends to be strikingly simple and mechanical. Consider, for example, an
s-expression grammar for strings like `(a0(b1(c2(d3))e5)f6)`:

```ebnf
letter = "a" | ... | "z" | "A" | ... | "Z"
digit  = "0" | ... | "9"
sexp   = sym | seq
sym    = letter (letter | digit)*
seq    = "(" sexp* ")"
```

This EBNF grammar would loosely translate to the following Scala code:

```scala
enum Sexp:
  case Sym(name: String)
  case Seq(items: List[Sexp])

val letter = satisfy(c => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))
val digit  = satisfy(c => c >= '0' && c <= '9')
val sexp: Parser[Sexp] = fix { self =>
  val sym = (letter ~ (letter | digit).many).map(Sym(_))
  val seq = self.many.between('(', ')').map(Seq(_))
  sym | seq
}
```

Notice how closely the Scala code mirrors the BNF grammar. Together with
primitives like `satisfy`, you can build parsers for any context-free language
using mainly the combinators for sequential (~) and alternative (|) composition,
and a fixed point combinator for recursion. Adding a few more common
combinators, we can define a small but powerful compositional DSL for parsing.
The combinator many is the counterpart for EBNF *. Later we develop a full-dress
library of combinators that covers many common needs.

In a practical combinator library you'd want to restrict the grammar you accept
to guarantee performance—such as enforcing left factoring or eliminating
left-recursion.

Parsers of this kind usually have applicative structure (via the ~ and map
above), and a monadic interface is also possible (Parsec-style) for
context-sensitive parsing, but that extra power rules out static analysis---more
on this later.

## Staging a parser type from the ground up

Before we can even begin talking about staging a parser, we need to first agree
on what we mean by a parser. Here's a
[rhyme](https://people.willamette.edu/~fruehr/haskell/seuss.html):

>  A Parser for Things\
>  is a function from Strings\
>  to Lists of Pairs\
>  of Things and Strings!

If we translate it to Scala, we get a parser for _ambiguous_ grammars:

```scala
trait Parser[A] extends (String => List[(A, String)]):
  def parse(input: String): Option[A] =
    this(input).collectFirst {
      case (result, leftover) if leftover.isEmpty => result
    }
```

this(input) returns a list of potential successes (handling ambiguity). Each
success is a pair: the parsed value A and the String that wasn't consumed. With
`collectFirst` we find the first valid result, and if there's none then we
return `None`.

However that is too general. It is safe to assume that most practical grammars
are not _inherently ambiguous_ and common data formats like JSON or TOML are
designed to be unambiguous (and in fact LR(1) or LL(1)), so we can essentially
remove the non-determinism:

```scala
trait Parser[A] extends (String => Option[(A, String)]):
  def parse(input: String): Option[A] = 
    this(input).map(_._1)
```

But we still can do better. By returning `Option[(A, String)]` (a value together
with the leftover string), we are using `String.substring(n)` internally, which
means for every value parsed you are allocating a string and increasing GC
pressure unnecessarily. We can instead return offsets to mark where in the
string we are at and use string indexing operations:

```scala
trait Parser[A] extends ((String, Int) => Option[(A, Int)]):
  def parse(input: String): Option[A] =
    this(input, 0).map(_._1)
```

Returning an `Option` means that a parsing failure is the absence of a value.
But users need precise feedback to fix their syntax errors, so an Option is kind
of a non-starter. We will not develop further error reporting, but since now we
have the current offset as part of the parser input, we can provide meaningful
error messages (line+column) with some helpers.

```scala
case class ParseFailure(offset: Int)

type Result[A] = Either[ParseFailure, A]

trait Parser[A] extends ((String, Int) => Result[(A, Int)]):
  def parse(input: String): Result[A] =
    this(input, 0).map(_._1)
```

Ok, we are getting closed to a _minimum viable_ parser. One final requirement is
the ability to represent recursive grammars, like the s-expression we defined
earlier. In general, you can't guarantee stack safety for complex, mutually
recursive grammars---JVM does not support TCO or TCMC. We'll use a trampoline to
make sure both nesting and repetition work for arbitrarily deep (long) chains of
characters:

```scala
import scala.util.control.TailCalls.TailRec

trait Parser[A] extends ((String, Int) => TailRec[Result[(A, Int)]]):
  def parse(in: String): Result[A] =
    this(in, 0).result.map(_._1)
```

And that was the last refinement, for our parser type. With this Parser
definition we can build simple (non-staged) stackless parsers and combinators. A
simple choice combinator would be defined as follows:

```scala
def |(that: Parser[A]): Parser[A] = (in, off) =>
  this(in, off).flatMap {
    case Right(v) => done(Right(v))
    case Left(_)  => that(in, off)
  }
```

Now that we have a type that covers our bases, we switch our attention to
metaprogramming. Staging a parser we can exploit the fact that the grammar is
known at compile-time, and we can neatly separate the dynamic parts (the input
string) from the static parts (the combinators), through quoting and splicing.

### Staging the parser

We could straightforward lift the previous Parser into a _staging_ lambda by
simply wrapping the inputs and outputs inside `Expr`s:

```scala
import scala.quoted.Expr

trait Parser[A] extends (
    (Expr[String], Expr[Int]) => Expr[TailRec[Result[(A, Int)]]]
  )
```

By doing this, we have essentially mutated the parser into a parser _generator_.
Instead of parsing a string it _writes the code_ that will parse a string. The
choice operator now is a _meta_-choice combinator and has the following
definition:


```scala
def |(that: Parser[A])(using Quotes): Parser[A] = (in, off) => '{
  ${ this(in, off) }.flatMap {
    case Right(v) => done(Right(v))
    case Left(_)  => ${ that(in, off) }
  }
}
```

Naively staging the parser buys us very little. In the | combinator, we
splice in 'this' to generate an `Expr[TailRec[Result]]`, but we still evaluate
it with .flatMap at runtime. Because the input string `in` is a runtime value,
and it is needed in order to pattern match the result, the entire body is
delayed to the runtime stage, completely wasting the fact that the structure of
the grammar rules are known statically. Even worse, the generated bytecode
balloons in size—a problem I'll cover shortly.

### Staging the control flow

To avoid that the entire expression becomes _dynamic_, we need to break this
dependency. Instead of generating an Either that implicitly tells you what to do
next, we could make the control flow _explicit_, by performing a CPS conversion.
In CPS, a parser doesn't return a value. Instead, it takes continuations:

```scala
type Res     = TailRec[Unit]
type Succ[A] = (Expr[A], Expr[Int]) => Expr[Res]
type Fail    = Expr[Int] => Expr[Res]

case class Cont[A](succ: Succ[A], fail: Fail)

trait Parser[A] extends ((Expr[String], Expr[Int], Cont[A]) => Expr[Res])
```

To encode the fact that a parser can fail, we provide two continuations: `succ`
and `fail`. On a staged parser continuations are compile-time functions, and so
they do not exist at runtime---unlike Either values. We maintain the trampoline
for stack safety. This is where the magic happens. The choice combinator for a
CPSed parser becomes:

```scala
def |(that: Parser[A])(using Quotes): Parser[A] =
  (in, off, k) =>
    this(in, off, Cont(k.succ, f1 =>
      that(in, off, Cont(k.succ, f2 =>
        k.fail('{
          if $f1 > $f2 then
            $f1
          else $f2
        }))
      ))
    )
```

When a parser succeeds, it doesn't wrap the result in an Either; it simply
invokes k.succ, seamlessly embedding the AST of the next parser directly into the
success path. And because every next parser does the exact same thing, you are
essentially _fusing_ the entire remaining grammar together.

Contrast this with (naive) unstaged parsers, where chains of combinators build
deeply nested closure objects on the heap, together with all the other
intermediate allocations needed at the boundaries, limiting parsing throughput.
Multi-stage programming allows us to keep the abstraction and beauty of parser
combinators, while pre-computing their structure at an earlier stage, generating
code looking like a handwritten descent parser.

### Integrating `Quotes`

One final (really) refinement. The Parser is a staging function and thus
most of our code will require a `(using Quotes)` to quote and splice
expressions. However, because our entire combinator DSL _exclusively_ returns
Parsers, we can solve this be making Parser a [context
function](context-functions):

```scala
trait Gen[A] extends ((Expr[String], Expr[Int], Cont[A]) => Expr[Res])

type Parser[A] = Quotes ?=> Gen[A]
```

This has a cascading effect, since any grammar you define with the combinator
library does not need to concern itself with a context parameter required for
implementation reasons. The (big) downside of using a context function is that
it precludes the use of lazy evaluation for defining mutually recursive
grammars, e.g. defining a `defer` combinator.

Ok, perhaps enough of beating around the bush. It's time for some actual
parsers.

[context-functions]: https://docs.scala-lang.org/scala3/reference/contextual/context-functions.html



## Putting the "parser" in parser combinators

Combinators we define later focus on grammar building, or structure. But before
that, we need some _lexical_ parsers. To parse terminal symbols:

```scala
def string(s: String): Parser[String] =
  (in, off, k) =>
    '{
      if ($in.startsWith(${ Expr(s) }, $off))
        ${ k.succ(Expr(s), '{ $off + ${ Expr(s.length) } }) }
      else
        ${ k.fail(off) }
    }
```

Because `s` is a compile-time value, we cannot reference it directly inside the
quote. Instead, we use Expr(s) to _lift_ the literal string into a syntax tree
so we can safely splice it into the generated code.

Note the careful management of staging boundaries. The conditional expression
as a whole is quoted, forming the runtime structure. As mentioned earlier, by
splicing the continuations we replace indirect jumps (closures) with direct
jumps (branching)---unlocking further optimizations like speculative execution.

`satisfy` is another basic building block, here defined as an `inline` function
to hide staging from users---ideally a user should not need to quote anything:

```scala
inline def satisfy(inline f: Char => Boolean): Parser[Char] =
  (in, off, k) =>
    '{
      if ($off < $in.length && f($in.charAt($off)))
        ${ k.succ('{ $in.charAt($off) }, '{ $off + 1 }) }
      else 
        ${ k.fail(off) }
    }

inline def char(inline c: Char): Parser[Char] = 
  satisfy(_ == c)
```

Notice a subtle difference with the `string` parser define ealier: since
`satisfy` has its predicate inlined, `char` also needs its parameter inlined,
and at the call sites `c` needs to be a literal. We could do this differently,
e.g. satify taking a staging function instead (Expr[Char] => Expr[Boolean]), and
then char would be not limited to char literals.

Scannerless means dealing with whitespace:

```scala
def ws: Parser[Unit] =
  (in, off, k) =>
    '{
      val n = $in.indexWhere(!_.isWhitespace, $off)
      val next = if n < 0 then $in.length else n
      ${ k.succ('{ () }, 'next) }
    }
```

To parse comments, text-based protocols or any kind of delimited string, we can
use `takeUntil`:

```scala
def takeUntil(c: Char): Parser[String] =
  (in, off, k) =>
    '{
      val n = $in.indexOf(${ Expr(c) }, $off)
      val next = if n < 0 then $in.length else n
      ${ k.succ('{ $in.substring($off, next) }, 'next) }
    }
```

### "Lifting" functions into parsers

A useful addition might be a staged parser reified from a direct-style parser---a
sort of escape hatch:

```scala
inline def apply[A: Type](inline p: (String, Int) => Option[(A, Int)])
  : Parser[A] =
  (in, off, k) =>
    '{
      p($in, $off) match
        case Some((a, next)) =>
          ${ k.succ('a, 'next) }
        case None =>
          ${ k.fail(off) }
    }
```

From this new factory method we can provide a regex parser:

```scala
import scala.util.matching.Regex

def regex(r: Regex): Parser[String] =
  Parser { (in, off) =>
    r.findPrefixMatchOf(in.substring(off))
     .map(m => (m.matched, off + m.end))
  }
```

This goes to show a library user does not need to worry about continuations.

## Staging the combinators

Following tradition, a natural fit for an applicative or monoidal-style
combinator API would be to derive instances of [Cats][cats] type classes.
However, we would get stuck. The fundamental mismatch is staging: because we
need to manipulate ASTs, we need a quotation context  and type
information made explicit to avoid type erasure across stages. The types simply
do not align.

[cats]: https://typelevel.org/cats/

However, the parser combinator API we provide is _almost_ standard, with
mapping, sequence, choice, recursion and _iteration_ as a separate combinator
(fold)---we'll see why later.

```scala
extension [A: Type](p: Parser[A])
  inline def map[B: Type](inline f: A => B): Parser[B] =
    (in, off, k) =>
      p(in, off, Cont((a, next) => k.succ('{ f($a) }, next), k.fail))
```

Transforming parsed text into domain objects gives a functor.


```scala
inline def pure[A: Type](inline value: A): Parser[A] =
  (_, off, k) => k.succ('{value}, off)

extension [A: Type](p: Parser[A])
  def ~[B: Type](that: Parser[B]): Parser[(A, B)] =
    (in, off, k) =>
      p(in, off,
        Cont((a, o1) =>
            that(
              in, o1,
              Cont((b, o2) => k.succ('{ ($a, $b) }, o2), k.fail)
            ),
          k.fail
        )
      )

  def *>[B: Type](other: Parser[B]): Parser[B] =
    (p ~ other).map(_._2)

  def <*[B: Type](other: Parser[B]): Parser[A] =
    (p ~ other).map(_._1)

```

Lifting a pure value and concatenation (~) forms an Applicative parser, with
sequence left and right added for convenience. We can easily now define
tokens:

```scala
inline def lexeme[A](inline p: Parser[A]): Parser[A] = p <* ws
inline def tok(inline c: Char): Parser[Char] = lexeme(char(c))
```

Or parse an HTTP request line:

```scala
// Parsing: "GET /api/users HTTP/1.1\r\n"
val method = takeUntil(' ') <* char(' ')   // extracts "GET"
val path   = takeUntil(' ') <* char(' ')   // extracts "/api/users"
val proto  = takeUntil('\r') <* string("\r\n") // extracts "HTTP/1.1"

val requestLine = (method ~ path ~ proto)
```
By introducing a parser that fails (empty) and a choice operator (|), our parser
exhibits an Alternative (or MonoidK) structure:

```scala
inline def empty[A: Type]: Parser[A] =
  (_, off, k) => k.fail(off)

extension [A: Type](p: Parser[A])
  def |(that: Parser[A]): Parser[A] =
    (in, off, k) =>
      p(in, off,
        Cont(k.succ,
          f1 =>
            that(in, off,
              Cont(k.succ,
                f2 => k.fail('{ if $f1 > $f2 then $f1 else $f2 }))
            ))
      )
```

With choice we can define `p?` which backtracks in case of failure:

```scala
extension [A: Type](p: Parser[A])
  def ? : Parser[Option[A]] = p.map(Option(_)) | pure(None)
```

As useful these combinators are, they fail to to handle arbitrarily nested
structures: parsers must be able to refer to themselves.

### Recursion

We are going to implement recursive grammars with a fixed point operator.
Staging Landin's knot is perhaps the gnarliest bit of code to get right in the
parser---or at least the one which gave me the most trouble.

```scala
def fix[A: Type](f: Parser[A] => Parser[A]): Parser[A] =
  lazy val self: Parser[A] = (in, off, k) => 
    f(self)(in, off, k)
  self
```

Consider a simple nested brackets parser:

```scala
val arr: Parser[List[Any]] = fix { self =>
  char('[') *> self <* char(']')
}
```

This is a toy example---it fails once it stops seeing open brackets---but it
exhibits recursion. When the compiler evaluates arr, it calls fix(f), which
returns the lazy self parser. To generate the final syntax tree, the compiler
must expand self, which immediately triggers the evaluation of f. The compiler
generates the AST for char('['), but then it encounters self in the sequence.
Because the macro eagerly attempts to resolve the entire tree at compile-time,
it expands self a second time. This blindly calls f again, generating another
char('['), which _hits self again_...you get the idea.

Foolishly, we are asking the compiler to unroll a recursive grammar for a
language that is potentially infinite into a flat, finite AST. We must stop the
compiler from unrolling the grammar---of course the recursion has to happen at
runtime.

But then we hit another problem: we need self to somehow honour its
continuations (Cont[A]). But these are not runtime closures, just syntax trees
holding the rest of the parser's logic (like parsing the closing `]`).
Thankfully staging allows us to move code from one stage to the next:

```scala
//  `Res` is an alias for `TailRec[Unit]`

object Cont:
  def lower[A: Type](k: Cont[A])(
    using Quotes
  ): Expr[((Any, Int) => Res, Int => Res)] =
    '{
      (
        (v: Any, n: Int) => ${ k.succ('{ v.asInstanceOf[A] }, 'n) },
        (fOff: Int) => ${ k.fail('fOff) }
      )
    }

  def apply[A: Type](k: Expr[((Any, Int) => Res, Int => Res)])(
    using Quotes
  ): Cont[A] =
    Cont(
      (v, n) => '{ tailcall($k._1($v, $n)) },
      fOff => '{ tailcall($k._2($fOff)) }
    )
```

`Cont.lower` splices the compile-time continuations into a _staged_ pair of
lambdas. Conversely, `Cont.apply` returns compile-time continuations from
splicing tailcalls to the provided staged lambdas. With these helpers acting as
our bridge, we can finally introduce a boundary between self generation and the
runtime recursion:

```scala
def fix[A: Type](f: Parser[A] => Parser[A]): Parser[A] =
  (in, off, start) =>
    '{
      def loop(o: Int, k: ((Any, Int) => Res, Int => Res)): Res = ${
        val self: Parser[A] = (_, nOff, nK) => 
          '{ tailcall(loop($nOff, ${ Cont.lower(nK) })) }
        
        f(self)(in, 'o, Cont('k))
      }
      tailcall(loop($off, ${ Cont.lower(start) }))
    }
```

The trampolined function `loop` ties the knot now, avoiding the trap, and `self`
just stages tailcalling loop. The parser returned by `fix` jumpstarts the loop.

You might wonder if introducing generic identifiers like loop, o, and k directly
into the generated code risks accidentally shadowing variables in the user's
grammar. Fortunately, Scala 3 macros are _hygienic_.

Perhaps to convince ourselves that these all make sense, we could look at the
(symbolic) macro expansion of the `loop` function. Assuming again a bracket
parser (`char('[') *> self <* char(']')`):

```scala
def loop(o: Int, k: ((Any, Int) => Res, Int => Res)): Res =
  if (in.charAt(o) == '[') {
    tailcall(loop(
      o + 1,
      (
        (v: Any, nOff: Int) => {
          if (in.charAt(nOff) == ']') {
            tailcall(k._1(v, nOff + 1))
          } else {
            tailcall(k._2(nOff))
          }
        },
        (fOff: Int) => {
          tailcall(k._2(fOff))
        }
      )
    ))
  } else {
    tailcall(k._2(o))
  }
```


For every call to `loop` it correctly tracks _unmatched_ open brackets via the
continuations. The tailcalls ensure that no matter how deep the nesting we are
stack-safe. Whew!

### Repetition

Kleene star can be succintly defined via mutual recursion. However, fold
(foldLeft) gives us an alternative route to define repetition (many) and some
other specialized combinators with better performance that with a fixed point
operator. 

The basic idea is to use fold for things that grow _horizontally_ (repetition)
and fix for things that grow _vertically_ (nesting). 

For `fix` to do its magic, we had to stage the continuations. We had no control
over the continuations, because they are hidden in the function the user
supplies. Folding applies a _known_ parser zero or more times and accumulates
the result.

```scala
extension [A: Type](p: Parser[A])
  inline def fold[B: Type](inline b: B)(inline f: (B, A) => B): Parser[B] =
    (in, off, k) =>
      '{
        def loop(cOff: Int, acc: B): Res = ${
          p(in, 'cOff,
            Cont(
              (a, next) => '{
                tailcall(loop($next, ${ Expr.betaReduce('{ f(acc, $a) }) }))
              },
              _ => k.succ('acc, 'cOff)
            )
          )
        }
        tailcall(loop($off, b))
      }
```

Since we know what to do if the parser succeeds (try again!), we can inline the
continuation in `p`, making `fold` a while loop.

Repetition is perhaps the only operation where the trampoline is strictly needed
for safety---note that in a CPS'd parser you do not return a value, so you can't
annotate the loop with @tailrec.

A rich DSL of iterative combinators can now be defined, in terms of fold:

```scala
extension [A: Type](p: Parser[A])
  def many: Parser[List[A]] =
    p.fold(List.empty[A])((acc, a) => a :: acc).map(_.reverse)

  def many1: Parser[List[A]] =
    (p ~ p.many).map(_ :: _)

  def skipMany: Parser[Unit] =
    p.fold(())((_, _) => ())

  def skipMany1: Parser[Unit] =
    p *> p.skipMany

  def sepBy[B: Type](sep: Parser[B]): Parser[List[A]] =
    sepBy1(sep) | pure(List.empty[A])

  def sepBy1[B: Type](sep: Parser[B]): Parser[List[A]] =
    (p ~ (sep *> p).many).map(_ :: _)
```

And from these the following looping parsers:

```scala
inline def takeWhile(inline f: Char => Boolean): Parser[String] =
  satisfy(f).skipMany.slice

inline def takeWhile1(inline f: Char => Boolean): Parser[String] =
  satisfy(f).skipMany1.slice

inline def skipWhile(inline f: Char => Boolean): Parser[Unit] =
  satisfy(f).skipMany
```

There is a little optimization here, where instead of calling `many` to get a
List[Char] and then call mkString, we use `skipMany` and then extract the
underlying matched sequence with this combinator:

```scala
extension [A: Type](p: Parser[A])
  def slice: Parser[String] =
    (in, off, k) =>
      p(in, off,
        Cont(
          (_, next) => k.succ('{ $in.substring($off, $next) }, next), 
          k.fail
        )
      )
```

### The elephant in the room 

Because Expr represents an AST, if `k.succ` is a massive block of generated
code, the compiler literally duplicates that code into your program bytecode. If
your parser is nesting a few | and ~ combinators, **your generated code grows
exponentially**---until the JVM eventually refuses to compile it. This
particular problem can be mitigated with _join points_.

A join point is like a let-binding, basically you'd need to identify when you
are duplicating a continuation, and instead insert a local function:


```scala {hl_lines=[3]}
def |(that: Parser[A]): Parser[A] =
  (in, off, k) => '{
    def succ(res: A, next: Int) = ${ k.succ('res, 'next) }

    ${
      val k2 = Cont(
        (res: Expr[A], o) => '{ tailcall(succ($res, $o)) },
        k.fail
      )
      this(in, off, Cont(k2.succ, f1 =>
        that(in, off, Cont(k2.succ, f2 =>
          k2.fail('{ if $f1 > $f2 then $f1 else $f2 })
        ))
      ))
    }
  }
```

With this change, both branches generate a lightweight method call to succ
rather than duplicating a potentially large AST. In a long chain of combinators,
the JVM's JIT compiler will easily inline these tiny delegate methods, meaning
all branches likely point to a single shared continuation.

However, this is not ideal, muddling the combinator with the optimization. A
_deep_ embedding---representing the parser as a data structure rather than a
function---would allow us to inspect the entire grammar before generation, and
among other things, insert join points.

## Generating the staged parser

Up until now, our parser has actually been a parser _generator_: it takes the
code representation of an input, an offset, and a pair of continuations, and
returns the code that weaves them all together. The final step is to take this
generator and build the staged lambda (the actual executable parser function)
that a macro can later splice into our program.

```scala
extension [A: Type](p: Parser[A])
  def compile(using Quotes): Expr[String => Either[ParseFailure, A]] =
    val pp = p.asInstanceOf[Gen[Any]] // pickling errors

    '{ (in: String) =>
      var res: Either[ParseFailure, Any] = null
      ${
        pp('{ in }, '{ 0 }, Cont(
          (v, off) => '{ res = Right($v); done(()) },
          fOff => '{ res = Left(ParseFailure($fOff)); done(()) }
        ))
      }.result
      res.asInstanceOf[Either[ParseFailure, A]]
    }
```

The `compile` method bridges this gap. It takes our final parser generator and
executes it, using a local variable (res) to capture the final value from the
top-level continuations. Once the trampoline loop finishes (`${...}.result`), we
return that variable.

Here is a parser that validates balanced brackets:

```scala
val p: Parser[Unit] = fix { self => 
  char('[') *> (self | pure(())) <* char(']') 
}
def bkt(using Quotes) = p.compile
```

We finally define a macro that builds our specialized parser, by splicing the
resulting `Expr` from `compile`, re-introducing the parser we defined
originally: String => Either[ParseFailure, A]. We've gone full circle, but was
the detour worth it?

```scala
inline def balanced: String => Either[ParseFailure, Unit] = ${ bkt }
```

We can now run our parser---on a different file:

```scala
println(balanced("[[[[[[]]]]]]"))
// Right(())

println(balanced("[" * 5001 + "]" * 5000))
// Left(ParseFailure(10001))
```

This is a very contrived example, but because of stackless recursion, we do not
have to worry about stack overflows. 
    
## Performance

To demonstrate and benchmark the combinator library, we are going to write a
_simplified_ JSON parser, assuming non-escaped strings, and with only rudimentary
number validation. The reason we choose JSON for benchmarking is because it can
be parsed _predictably_---we want to test staging, not backtracking.

```scala
enum Json {
  case JObject(fields: Map[String, Json])
  case JArray(items: List[Json])
  case JBoolean(value: Boolean)
  case JString(value: String)
  case JNumber(value: Double)
  case JNull
}
```


```scala
val json: Parser[Json] = fix: self =>
  import Json.*

  val str = takeUntil('"').between('"', '"')

  val jNull = string("null").as(JNull)
  val jBool =
    (string("true").as(true) | string("false").as(false)).map(JBoolean(_))
  val jStr = str.map(JString(_))
  val jNum = takeWhile1(c => c == '-' || c == '.' || c.isDigit).map(
    _.toDouble
  ).map(JNumber(_))
  val jArr = lexeme(self).sepBy(tok(',')).between('[', ']').map(JArray(_))
  val jObj = ((str <* tok(':')) ~ lexeme(self)).sepBy(tok(',')).between('{', '}')
    .map(fs => Json.JObject(fs.toMap))

  jNull | jBool | jNum | jStr | jArr | jObj
```

### Benchmark

The benchmark compares three implementations:
- the staged `json` parser above with the combinators from this post
- a baseline handwritten recursive-descent JSON parser with single-character
lookahead (an LL(1) parser); at the other end of the spectrum,
- A direct-style parser combinator using Cats `Eval`, sharing the _exact_ same
  DSL as the staged version.

The code for each is available [here][staged], [here][misc], and
[here][unstaged], respectively.

All three implementations use the same underlying primitives (indexOf,
indexWhere, startsWith) for lexical parsing, ensuring that keyword and string
scanning do not influence results. Similary, they all use a trampoline for
recursion. This setup allows us to (or at least try to) isolate the performance
impact of the combinator plumbing itself.

[staged]: https://gist.github.com/moleike/6fa86a3907a9d42dff349a0b53c4e809#file-staged-scala
[misc]: https://gist.github.com/moleike/6fa86a3907a9d42dff349a0b53c4e809#file-misc-scala
[unstaged]: https://gist.github.com/moleike/6fa86a3907a9d42dff349a0b53c4e809#file-unstaged-scala

### Results

All benchmarks were performed on an Apple M1 Pro (16GB RAM). Running the parsers
with a 1MB and 5MB JSON file, I get the following results:

{{< figure src="/images/benchmark_speed.png" class="center" alt="centering"
width="100%">}}

Because the non-staged `Eval` implementation is well over an order of magnitude
slower than the others, we use logarithmic scale. The staged parser finishes in
roughly 2/3 the time of the handwritten version.

To understand why we see such a performance gap, we ran the benchmark with the
JVM GC profiler (-prof gc), which measures the memory allocated per operation
(gc.alloc.rate.norm):

{{< figure src="/images/benchmark_memory.png" class="center" alt="centering"
width="100%">}}

These numbers account too for the JSON AST allocations, so it's not strictly
speaking parsing allocation rate---we would need to run validators, not parsers,
instead. Nonetheless, it clearly shows how much we have reduced memory churning
with the CPSed version, with even less allocations than a tedious handwritten
parser, all while maintaining the same declarative DSL of a non-staged
combinator library.

## Final remarks

In the Scala ecosystem, macros are typically relegated to eliminating
boilerplate or deriving type classes. However, with support for quotation-based
staging, we get something more like macros on _steroids_.

I got really intrigued about multi-stage programming and using staging for
performance after I read some years ago a couple of papers: [*A Typed, Algebraic
Approach to Parsing*](https://dl.acm.org/doi/10.1145/3314221.3314625)
(Krishnaswami & Yallop, 2019) and [*Staged Selective Parser
Combinators*](https://dl.acm.org/doi/10.1145/3409002) (Willis, Wu, & Pickering,
2020), but those use MetaOCaml and Typed Template Haskell. So what a treat that
Scala 3 comes with support for MSP out of the box! 

There is a paper dating back to 2014 on Scala, [*Staged Parser Combinators for
Efficient Data Processing*](https://dl.acm.org/doi/10.1145/2714064.2660241)
(Jonnalagedda, Coppey, Stucki, Rompf, & Odersky) which specifically explored the
ideas I discussed, but based on Lightweight Modular Staging (LMS), which was a
precursor of Scala 3 MSP.
