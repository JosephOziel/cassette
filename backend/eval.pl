:- module(eval, [eval/5, eval_list/5]).
:- use_module(tape).
:- use_module(unify).
:- use_module(builtins).

% constructs
as_c([], CTX, Tape, CTX, Tape).
as_c([Pat], CTX, Tape, NCTX, NTape) :-
    NTape @- Tape^Val,
    !, unify(Val, Pat, CTX, NCTX).
as_c([Pat|Rest], CTX, Tape, NCTX, NTape) :-
    as_c([Pat], CTX, Tape, CTX0, Tape0),
    as_c(Rest, CTX0, Tape0, NCTX, NTape).

tape_group([], fn([], CTX), CTX).
tape_group([tape(Exprs)|ERest], fn([tape(Tape)|VRest], CTX), CTX) :-
    Empty @- !, tape_c(Exprs, CTX, Empty, Tape),
    tape_group(ERest, fn(VRest, CTX), CTX).
tape_group([Expr|ERest], fn([Expr|VRest], CTX), CTX) :- tape_group(ERest, fn(VRest, CTX), CTX).

tape_c([], _CTX, (L, R), MTape) :- reverse(L, NL), MTape = (NL, R).
tape_c([Exprs|Rest], CTX, Tape, NTape) :-
    tape_group(Exprs, Fn, CTX),
    Tape0 @- Tape+Fn,
    tape_c(Rest, CTX, Tape0, NTape).

cond_c([], Else, case([lit(yes)], [], Else)).
cond_c([branch(Cond, Ins)|IRest], Else, case([lit(yes)], [branch([pat_lit(yes)], Cond, Ins)|BRest], Else)) :-
       cond_c(IRest, Else, case([lit(yes)], BRest, Else)).

case_c(none, Branches, CTX, Tape, NCTX, NTape) :-
    case_c(Tape, Branches, CTX, Tape, NCTX, NTape); !, fail.
case_c(Expr, branch(Pats, When, Ins), CTX, _Tape, NCTX, NTape) :-
    reverse(Pats, Pats1),
    as_c(Pats1, CTX, Expr, CTX1, Tape),
    (   When = []
    ;   Empty @- !, eval2_list(When, CTX1, CTX, Empty, _CTX0, Tape0), lit(yes) @- @Tape0),
    eval2_list(Ins, CTX1, CTX, Tape, NCTX, NTape).

%unquote_c(unquote(Expr), Out, CTX) :- unquote_c(Expr, Out, CTX).
%unquote_c(splice(Expr), Out, CTX) :- splice_c(Expr, [], CTX, Out).
unquote_c(Expr, NTape, CTX) :-
    Empty @- !,
    eval(Expr, CTX, Empty, _, NTape); !, fail.

splice_c([], Out, _, Out).
splice_c([Expr|ERest], Out, CTX, Res) :-
    Empty @- !,
    (   eval_list(Expr, CTX, Empty, _, NTape); !, fail),
    NOut @- NTape++Out,
    splice_c(ERest, NOut, CTX, Res).

% TODO: nested quasiquoting https://docs.racket-lang.org/guide/qq.html.
% evaluate them
quasiquote_c([], Out, _, Out).
quasiquote_c([unquote(E)|In], Out, CTX, Res) :-
    !, unquote_c(E, O, CTX),
    Out1 @- Out++O,
    quasiquote_c(In, Out1, CTX, Res).
quasiquote_c([splice(Exprs)|In], Out, CTX, Res) :-
    Empty @- !,
    reverse(Exprs, RExprs),
    !, splice_c(RExprs, Empty, CTX, O),
    NOut @- Out++O,
    quasiquote_c(In, NOut, CTX, Res).
quasiquote_c([E|In], Out, CTX, Res) :-
    to_tape([E], T),
    Out1 @- Out++T,
    quasiquote_c(In, Out1, CTX, Res).

friedquote_c([], Res, Tape, Tape, Res).
friedquote_c([hole|FRest], Acc, Tape, NTape, Res) :-
    (Tape0 @- Tape^H; !, fail),
    NAcc @- Acc+H,
    friedquote_c(FRest, NAcc, Tape0, NTape, Res).
friedquote_c([splice|FRest], Acc, Tape, NTape, Res) :-
    (Tape0 @- Tape^quote(Quote); !, fail),
    NAcc @- Quote++Acc,
    friedquote_c(FRest, NAcc, Tape0, NTape, Res).
friedquote_c([E|FRest], Acc, Tape, NTape, Res) :-
    NAcc @- Acc+E,
    friedquote_c(FRest, NAcc, Tape, NTape, Res).

quote_c(AST, (AST, [])).

% make cond sugar for a case with a bunch of when clauses

% evalutation
eval(if(Expr, If, Else), CTX, Tape, NCTX, NTape) :-
    (Expr = [], Cond = none; Cond = Expr),
    Case = case(Cond, [branch([pat_lit(yes)], [], If)], Else),
    eval(Case, CTX, Tape, NCTX, NTape).

eval(cond(Branches, Else), CTX, Tape, NCTX, NTape) :-
    cond_c(Branches, Else, Case), eval(Case, CTX, Tape, NCTX, NTape).

eval(case(_, [], []), CTX, Tape, CTX, Tape).
eval(case(_, [], Else), CTX, Tape, NCTX, NTape) :-
    eval_list(Else, CTX, Tape, NCTX, NTape).
eval(case(Expr, [Branch|BRest], Else), CTX, Tape, NCTX, NTape) :-
    (   Expr = none -> case_c(Expr, Branch, CTX, Tape, NCTX, NTape)
    ;   Empty @- !, eval_list(Expr, CTX, Empty, CTX0, Tape0) ->
        case_c(Tape0, Branch, CTX0, Tape0, NCTX, NTape)
    ;   eval(case(Expr, BRest, Else), CTX, Tape, NCTX, NTape)).

eval(sym("pass"), CTX, Tape, CTX, Tape).
eval(sym("trace!"), CTX, Tape, CTX, Tape) :- trace.
eval(sym("gtrace!"), CTX, Tape, CTX, Tape) :- gtrace.

eval(sym(Name), CTX, Tape, CTX, NTape) :-
    atom_string(N, Name),
    fn(AST, FCTX) = CTX.get(N),
    eval_list(AST, FCTX, Tape, _CTX, NTape).
eval(sym(Name), CTX, Tape, CTX, NTape) :-
    atom_string(N, Name),
    NTape @- Tape+CTX.get(N).

eval(sym(Name), CTX, Tape, NCTX, NTape) :-
    (   builtin(Name, CTX, Tape, NCTX, NTape)
    ;   Name = "print_tape" -> print_term(Tape, []), nl
    ;   !, fail). % TODO: error system to give an error if this happens

eval(lit(Lit), CTX, Tape, CTX, NTape) :-
    NTape @- Tape+lit(Lit).

eval(as(Pats), CTX, Tape, NCTX, NTape) :-
    as_c(Pats, CTX, Tape, NCTX, NTape).

eval(tape(Exprs), CTX, Tape, CTX, NTape) :-
    tape_c(Exprs, CTX, Tape, MTape),
    NTape @- Tape+tape(MTape).

eval(quasiquote(AST), CTX, Tape, CTX, NTape) :-
    Empty @- !,
    quasiquote_c(AST, Empty, CTX, Quote),
    NTape @- Tape+quote(Quote).

eval(friedquote(AST), CTX, Tape, CTX, NTape) :-
    reverse(AST, RAST),
    Empty @- !,
    !, friedquote_c(RAST, Empty, Tape, Tape0, Quote),
    NTape @- Tape0+quote(Quote).

eval(quote(AST), CTX, Tape, CTX, NTape) :-
    quote_c(AST, Quote),
    NTape @- Tape+quote(Quote).

eval(fn(Name, Args, When, Body), CTX, Tape, NCTX, Tape) :-
    atom_string(N, Name),
    Else = [error(format("match_error: no match for function ~a", N))],
    (   fn([case(none, Branches, _Else)], _CTX) = CTX.get(N) ->
        append(Branches, [branch(Args, When, Body)], NBranches),
        AST = case(none, NBranches, Else)
    ;   AST = case(none, [branch(Args, When, Body)], Else)),
    FCTX = CTX.put(N, fn([AST], FCTX)),
    NCTX = CTX.put(N, fn([AST], FCTX)).

eval(error(Msg), _, _, _, _) :- throw(Msg).

% evaluating a list of instructions
eval_list([], CTX, Tape, CTX, Tape).
eval_list([I|Rest], CTX, Tape, NCTX, NTape) :-
    !, eval(I, CTX, Tape, CTX0, Tape0),
    eval_list(Rest, CTX0, Tape0, NCTX, NTape).

eval2_list([], _CTX1, CTX2, Tape, CTX2, Tape).
eval2_list([I|Rest], CTX1, CTX2, Tape, NCTX, NTape) :-
    eval2(I, CTX1, CTX2, Tape, CTX3, Tape0),
    eval2_list(Rest, CTX1, CTX3, Tape0, NCTX, NTape).

eval2(as(Pats), _CTX1, CTX2, Tape, NCTX, NTape) :-
    eval(as(Pats), CTX2, Tape, NCTX, NTape).
eval2(sym(Name), CTX1, CTX2, Tape, CTX2, NTape) :-
    (   eval(sym(Name), CTX1, Tape, _CTX, NTape)
    ;   eval(sym(Name), CTX2, Tape, _CTX, NTape)).
eval2(Expr, _CTX1, CTX2, Tape, NCTX, NTape) :-
    eval(Expr, CTX2, Tape, NCTX, NTape).

% utils

% used to be something here
