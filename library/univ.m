%---------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et wm=0 tw=0
%---------------------------------------------------------------------------%
% Copyright (C) 1994-2010 The University of Melbourne.
% This file may only be copied under the terms of the GNU Library General
% Public License - see the file COPYING.LIB in the Mercury distribution.
%---------------------------------------------------------------------------%
%
% File: univ.m.
% Main author: fjh.
% Stability: medium.
%
% The universal type `univ'
%
%---------------------------------------------------------------------------%
%---------------------------------------------------------------------------%

:- module univ.
:- interface.

:- import_module type_desc.

%---------------------------------------------------------------------------%

    % An object of type `univ' can hold the type and value of an object of any
    % other type.
    %
:- type univ.

    % type_to_univ(Object, Univ).
    %
    % True iff the type stored in `Univ' is the same as the type of `Object',
    % and the value stored in `Univ' is equal to the value of `Object'.
    %
    % Operational, the forwards mode converts an object to type `univ',
    % while the reverse mode converts the value stored in `Univ'
    % to the type of `Object', but fails if the type stored in `Univ'
    % does not match the type of `Object'.
    %
:- pred type_to_univ(T, univ).
:- mode type_to_univ(di, uo) is det.
:- mode type_to_univ(in, out) is det.
:- mode type_to_univ(out, in) is semidet.

    % univ_to_type(Univ, Object) :- type_to_univ(Object, Univ).
    %
:- pred univ_to_type(univ, T).
:- mode univ_to_type(in, out) is semidet.
:- mode univ_to_type(out, in) is det.
:- mode univ_to_type(uo, di) is det.

    % The function univ/1 provides the same functionality as type_to_univ/2.
    % univ(Object) = Univ :- type_to_univ(Object, Univ).
    %
:- func univ(T) = univ.
:- mode univ(in) = out is det.
:- mode univ(di) = uo is det.
:- mode univ(out) = in is semidet.

    % det_univ_to_type(Univ, Object).
    %
    % The same as the forwards mode of univ_to_type, but aborts
    % if univ_to_type fails.
    %
:- pred det_univ_to_type(univ::in, T::out) is det.

    % univ_type(Univ).
    %
    % Returns the type_desc for the type stored in `Univ'.
    %
:- func univ_type(univ) = type_desc.

    % univ_value(Univ).
    %
    % Returns the value of the object stored in Univ.
    %
:- some [T] func univ_value(univ) = T.

%---------------------------------------------------------------------------%
%---------------------------------------------------------------------------%

:- implementation.

:- import_module require.
:- import_module list.
:- import_module string.

%---------------------------------------------------------------------------%

    % We call the constructor for univs `univ_cons' to avoid ambiguity
    % with the univ/1 function which returns a univ.
    %
:- type univ
    --->    some [T] univ_cons(T).

univ_to_type(Univ, X) :- type_to_univ(X, Univ).

univ(X) = Univ :- type_to_univ(X, Univ).

det_univ_to_type(Univ, X) :-
    ( if type_to_univ(X0, Univ) then
        X = X0
    else
        UnivTypeName = type_name(univ_type(Univ)),
        ObjectTypeName = type_name(type_of(X)),
        string.append_list(["det_univ_to_type: conversion failed\n",
            "\tUniv Type: ", UnivTypeName, "\n",
            "\tObject Type: ", ObjectTypeName], ErrorString),
        error(ErrorString)
    ).

univ_value(univ_cons(X)) = X.

:- pragma promise_equivalent_clauses(type_to_univ/2).

type_to_univ(T::di, Univ::uo) :-
    Univ0 = 'new univ_cons'(T),
    unsafe_promise_unique(Univ0, Univ).
type_to_univ(T::in, Univ::out) :-
    Univ = 'new univ_cons'(T).
type_to_univ(T::out, Univ::in) :-
    Univ = univ_cons(T0),
    private_builtin.typed_unify(T0, T).

univ_type(Univ) = type_of(univ_value(Univ)).

:- pred construct_univ(T::in, univ::out) is det.
:- pragma foreign_export("C", construct_univ(in, out), "ML_construct_univ").
:- pragma foreign_export("C#", construct_univ(in, out), "ML_construct_univ").
:- pragma foreign_export("Java", construct_univ(in, out), "ML_construct_univ").

construct_univ(X, Univ) :-
    Univ = univ(X).

:- some [T] pred unravel_univ(univ::in, T::out) is det.
:- pragma foreign_export("C", unravel_univ(in, out), "ML_unravel_univ").
:- pragma foreign_export("C#", unravel_univ(in, out), "ML_unravel_univ").
:- pragma foreign_export("Java", unravel_univ(in, out), "ML_unravel_univ").

unravel_univ(Univ, X) :-
    univ_value(Univ) = X.

%---------------------------------------------------------------------------%
:- end_module univ.
%---------------------------------------------------------------------------%
