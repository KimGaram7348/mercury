%-----------------------------------------------------------------------------%
% Copyright (C) 1995 University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% The job of this module is to delete dead procedures from the HLDS.
%
% Main author: zs.
%
%-----------------------------------------------------------------------------%

:- module dead_proc_elim.

:- interface.

:- import_module hlds_module, io.

:- pred dead_proc_elim(module_info, module_info, io__state, io__state).
:- mode dead_proc_elim(in, out, di, uo) is det.

:- pred dead_proc_elim__analyze(module_info, needed_map).
:- mode dead_proc_elim__analyze(in, out) is det.

:- pred dead_proc_elim__eliminate(module_info, needed_map, module_info,
	io__state, io__state).
:- mode dead_proc_elim__eliminate(in, in, out, di, uo) is det.

:- type needed_map ==	map(pred_proc_id, maybe(int)).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.
:- import_module hlds_pred, hlds_goal, hlds_data, prog_data.
:- import_module passes_aux, globals, options.
:- import_module int, list, set, queue, map, bool, std_util.

%-----------------------------------------------------------------------------%

% The algorithm has three main data structures:
%
%	- a map of procedures known to be needed to the number of their uses
%	  (if they are a candidate for elimination after inlining them)
%
%	- a queue of procedures to be examined,
%
%	- a set of procedures that have been examined.
%
% The needed map and the queue are both initialized with the ids of procedures
% exported from the module, including the ones generated by the compiler.
% The algorithm then takes the ids of procedures from the queue one at a time,
% and if the procedure hasn't been examined before, traverses the procedure
% definition to find all mention of other procedures, including those in
% higher order terms. Their ids are then put into both the needed map and
% the queue.
%
% The final pass of the algorithm deletes from the HLDS any procedure
% that is not in the needed map.

:- type proc_queue ==	queue(pred_proc_id).
:- type examined_set ==	set(pred_proc_id).

dead_proc_elim(ModuleInfo0, ModuleInfo, State0, State) :-
	dead_proc_elim__analyze(ModuleInfo0, Needed),
	dead_proc_elim__eliminate(ModuleInfo0, Needed, ModuleInfo,
		State0, State).

%-----------------------------------------------------------------------------%

dead_proc_elim__analyze(ModuleInfo0, Needed) :-
	set__init(Examined0),
	dead_proc_elim__initialize(ModuleInfo0, Queue0, Needed0),
	dead_proc_elim__examine(Queue0, Examined0, ModuleInfo0,
		Needed0, Needed).

:- pred dead_proc_elim__initialize(module_info, proc_queue, needed_map).
:- mode dead_proc_elim__initialize(in, out, out) is det.

dead_proc_elim__initialize(ModuleInfo, Queue, Needed) :-
	queue__init(Queue0),
	map__init(Needed0),
	module_info_predids(ModuleInfo, PredIds),
	module_info_preds(ModuleInfo, PredTable),
	dead_proc_elim__initialize_preds(PredIds, PredTable,
		Queue0, Queue1, Needed0, Needed1),
	module_info_get_pragma_exported_procs(ModuleInfo, PragmaExports),
	dead_proc_elim__initialize_pragma_exports(PragmaExports,
		Queue1, Queue, Needed1, Needed).

:- pred dead_proc_elim__initialize_preds(list(pred_id), pred_table,
	proc_queue, proc_queue, needed_map, needed_map).
:- mode dead_proc_elim__initialize_preds(in, in, in, out, in, out) is det.

dead_proc_elim__initialize_preds([], _PredTable, Queue, Queue, Needed, Needed).
dead_proc_elim__initialize_preds([PredId | PredIds], PredTable,
		Queue0, Queue, Needed0, Needed) :-
	map__lookup(PredTable, PredId, PredInfo),
	pred_info_exported_procids(PredInfo, ProcIds),
	dead_proc_elim__initialize_procs(PredId, ProcIds,
		Queue0, Queue1, Needed0, Needed1),
	dead_proc_elim__initialize_preds(PredIds, PredTable,
		Queue1, Queue, Needed1, Needed).

:- pred dead_proc_elim__initialize_procs(pred_id, list(proc_id),
	proc_queue, proc_queue, needed_map, needed_map).
:- mode dead_proc_elim__initialize_procs(in, in, in, out, in, out) is det.

dead_proc_elim__initialize_procs(_PredId, [], Queue, Queue, Needed, Needed).
dead_proc_elim__initialize_procs(PredId, [ProcId | ProcIds],
		Queue0, Queue, Needed0, Needed) :-
	queue__put(Queue0, proc(PredId, ProcId), Queue1),
	map__set(Needed0, proc(PredId, ProcId), no, Needed1),
	dead_proc_elim__initialize_procs(PredId, ProcIds,
		Queue1, Queue, Needed1, Needed).

	% Add all procs that are exported to C by a pragma(export, ...) dec.
	% to the needed_map.
:- pred dead_proc_elim__initialize_pragma_exports(list(pragma_exported_proc),
	proc_queue, proc_queue, needed_map, needed_map).
:- mode dead_proc_elim__initialize_pragma_exports(in, in, out, in, out) is det.
dead_proc_elim__initialize_pragma_exports([], Queue, Queue, Needed, Needed).
dead_proc_elim__initialize_pragma_exports([P|Ps],
		Queue0, Queue, Needed0, Needed) :-
	P = pragma_exported_proc(PredId, ProcId, _CFunction),
	queue__put(Queue0, proc(PredId, ProcId), Queue1),
	map__set(Needed0, proc(PredId, ProcId), no, Needed1),
	dead_proc_elim__initialize_pragma_exports(Ps,
		Queue1, Queue, Needed1, Needed).


%-----------------------------------------------------------------------------%

:- pred dead_proc_elim__examine(proc_queue, examined_set, module_info,
	needed_map, needed_map).
:- mode dead_proc_elim__examine(in, in, in, in, out) is det.

dead_proc_elim__examine(Queue0, Examined0, ModuleInfo, Needed0, Needed) :-
	% see if the queue is empty
	( queue__get(Queue0, PredProcId, Queue1) ->
		% see if the next element has been examined before
		( set__member(PredProcId, Examined0) ->
			dead_proc_elim__examine(Queue1, Examined0, ModuleInfo,
				Needed0, Needed)
		;
			set__insert(Examined0, PredProcId, Examined1),
			dead_proc_elim__examine_proc(PredProcId, ModuleInfo,
				Queue1, Queue2, Needed0, Needed1),
			dead_proc_elim__examine(Queue2, Examined1, ModuleInfo,
				Needed1, Needed)
		)
	;
		Needed = Needed0
	).

:- pred dead_proc_elim__examine_proc(pred_proc_id, module_info,
	proc_queue, proc_queue, needed_map, needed_map).
:- mode dead_proc_elim__examine_proc(in, in, in, out, in, out) is det.

dead_proc_elim__examine_proc(proc(PredId, ProcId), ModuleInfo, Queue0, Queue,
		Needed0, Needed) :-
	(
		module_info_preds(ModuleInfo, PredTable),
		map__lookup(PredTable, PredId, PredInfo),
		pred_info_non_imported_procids(PredInfo, ProcIds),
		list__member(ProcId, ProcIds),
		pred_info_procedures(PredInfo, ProcTable),
		map__lookup(ProcTable, ProcId, ProcInfo)
	->
		proc_info_goal(ProcInfo, Goal),
		dead_proc_elim__traverse_goal(Goal, proc(PredId, ProcId),
			Queue0, Queue, Needed0, Needed)
	;
		Queue = Queue0,
		Needed = Needed0
	).

%-----------------------------------------------------------------------------%

:- pred dead_proc_elim__traverse_goals(list(hlds__goal), pred_proc_id,
	proc_queue, proc_queue, needed_map, needed_map).
:- mode dead_proc_elim__traverse_goals(in, in, in, out, in, out) is det.

dead_proc_elim__traverse_goals([], _, Queue, Queue, Needed, Needed).
dead_proc_elim__traverse_goals([Goal | Goals], CurrProc, Queue0, Queue,
		Needed0, Needed) :-
	dead_proc_elim__traverse_goal(Goal, CurrProc, Queue0, Queue1,
		Needed0, Needed1),
	dead_proc_elim__traverse_goals(Goals, CurrProc, Queue1, Queue,
		Needed1, Needed).

:- pred dead_proc_elim__traverse_cases(list(case), pred_proc_id,
	proc_queue, proc_queue, needed_map, needed_map).
:- mode dead_proc_elim__traverse_cases(in, in, in, out, in, out) is det.

dead_proc_elim__traverse_cases([], _CurrProc, Queue, Queue, Needed, Needed).
dead_proc_elim__traverse_cases([case(_, Goal) | Cases], CurrProc, Queue0, Queue,
		Needed0, Needed) :-
	dead_proc_elim__traverse_goal(Goal, CurrProc, Queue0, Queue1,
		Needed0, Needed1),
	dead_proc_elim__traverse_cases(Cases, CurrProc, Queue1, Queue,
		Needed1, Needed).

:- pred dead_proc_elim__traverse_goal(hlds__goal, pred_proc_id,
	proc_queue, proc_queue, needed_map, needed_map).
:- mode dead_proc_elim__traverse_goal(in, in, in, out, in, out) is det.

dead_proc_elim__traverse_goal(GoalExpr - _, CurrProc, Queue0, Queue,
		Needed0, Needed) :-
	dead_proc_elim__traverse_expr(GoalExpr, CurrProc, Queue0, Queue,
		Needed0, Needed).

:- pred dead_proc_elim__traverse_expr(hlds__goal_expr, pred_proc_id,
	proc_queue, proc_queue, needed_map, needed_map).
:- mode dead_proc_elim__traverse_expr(in, in, in, out, in, out) is det.

dead_proc_elim__traverse_expr(disj(Goals, _), CurrProc, Queue0, Queue,
		Needed0, Needed) :-
	dead_proc_elim__traverse_goals(Goals, CurrProc, Queue0, Queue,
		Needed0, Needed).
dead_proc_elim__traverse_expr(conj(Goals), CurrProc, Queue0, Queue,
		Needed0, Needed) :-
	dead_proc_elim__traverse_goals(Goals, CurrProc, Queue0, Queue,
		Needed0, Needed).
dead_proc_elim__traverse_expr(not(Goal), CurrProc, Queue0, Queue,
		Needed0, Needed) :-
	dead_proc_elim__traverse_goal(Goal, CurrProc, Queue0, Queue,
		Needed0, Needed).
dead_proc_elim__traverse_expr(some(_, Goal), CurrProc, Queue0, Queue,
		Needed0, Needed) :-
	dead_proc_elim__traverse_goal(Goal, CurrProc, Queue0, Queue,
		Needed0, Needed).
dead_proc_elim__traverse_expr(switch(_, _, Cases, _), CurrProc, Queue0, Queue,
		Needed0, Needed) :-
	dead_proc_elim__traverse_cases(Cases, CurrProc, Queue0, Queue,
		Needed0, Needed).
dead_proc_elim__traverse_expr(if_then_else(_, Cond, Then, Else, _),
		CurrProc, Queue0, Queue, Needed0, Needed) :-
	dead_proc_elim__traverse_goal(Cond, CurrProc, Queue0, Queue1,
		Needed0, Needed1),
	dead_proc_elim__traverse_goal(Then, CurrProc, Queue1, Queue2,
		Needed1, Needed2),
	dead_proc_elim__traverse_goal(Else, CurrProc, Queue2, Queue,
		Needed2, Needed).
dead_proc_elim__traverse_expr(higher_order_call(_,_,_,_,_,_), _,
		Queue, Queue, Needed, Needed).
dead_proc_elim__traverse_expr(call(PredId, ProcId, _,_,_,_,_),
		CurrProc, Queue0, Queue, Needed0, Needed) :-
	queue__put(Queue0, proc(PredId, ProcId), Queue),
	( proc(PredId, ProcId) = CurrProc ->
		NewNotation = no
	; map__search(Needed0, proc(PredId, ProcId), OldNotation) ->
		(
			OldNotation = no,
			NewNotation = no
		;
			OldNotation = yes(Count0),
			Count is Count0 + 1,
			NewNotation = yes(Count)
		)
	;
		NewNotation = yes(1)
	),
	map__set(Needed0, proc(PredId, ProcId), NewNotation, Needed).
dead_proc_elim__traverse_expr(pragma_c_code(_, _, PredId, ProcId, _, _),
		_CurrProc, Queue0, Queue, Needed0, Needed) :-
	queue__put(Queue0, proc(PredId, ProcId), Queue),
	map__set(Needed0, proc(PredId, ProcId), no, Needed).
dead_proc_elim__traverse_expr(unify(_,_,_, Uni, _), _CurrProc, Queue0, Queue,
		Needed0, Needed) :-
	(
		Uni = construct(_, ConsId, _, _),
		( ConsId = pred_const(PredId, ProcId)
		; ConsId = code_addr_const(PredId, ProcId)
		)
	->
		queue__put(Queue0, proc(PredId, ProcId), Queue),
		map__set(Needed0, proc(PredId, ProcId), no, Needed)
	;
		Queue = Queue0,
		Needed = Needed0
	).

	% XXX I am not sure about the handling of pragmas and unifications.

%-----------------------------------------------------------------------------%

dead_proc_elim__eliminate(ModuleInfo0, Needed, ModuleInfo, State0, State) :-
	module_info_predids(ModuleInfo0, PredIds),
	module_info_preds(ModuleInfo0, PredTable0),
	dead_proc_elim__eliminate_preds(PredIds, Needed, ModuleInfo0,
		PredTable0, PredTable, State0, State),
	module_info_set_preds(ModuleInfo0, PredTable, ModuleInfo).

:- pred dead_proc_elim__eliminate_preds(list(pred_id), needed_map, module_info,
	pred_table, pred_table, io__state, io__state).
:- mode dead_proc_elim__eliminate_preds(in, in, in, in, out, di, uo) is det.

dead_proc_elim__eliminate_preds([], _Needed, _, PredTable, PredTable) --> [].
dead_proc_elim__eliminate_preds([PredId | PredIds], Needed, ModuleInfo,
		PredTable0, PredTable) -->
	dead_proc_elim__eliminate_pred(PredId, Needed, ModuleInfo,
		PredTable0, PredTable1),
	dead_proc_elim__eliminate_preds(PredIds, Needed, ModuleInfo,
		PredTable1, PredTable).

:- pred dead_proc_elim__eliminate_pred(pred_id, needed_map, module_info,
	pred_table, pred_table, io__state, io__state).
:- mode dead_proc_elim__eliminate_pred(in, in, in, in, out, di, uo) is det.

dead_proc_elim__eliminate_pred(PredId, Needed, ModuleInfo,
		PredTable0, PredTable, State0, State) :-
	map__lookup(PredTable0, PredId, PredInfo0),
	pred_info_import_status(PredInfo0, Status),
	(
		( Status = local, Keep = no
		; Status = pseudo_exported, Keep = yes(0)
		)
	->
		pred_info_procids(PredInfo0, ProcIds0),
		pred_info_procedures(PredInfo0, ProcTable0),
		pred_info_name(PredInfo0, Name),
		pred_info_arity(PredInfo0, Arity),
		dead_proc_elim__eliminate_procs(PredId, ProcIds0, Needed, Keep,
			Name, Arity, ModuleInfo, ProcTable0, ProcTable,
			State0, State),
		pred_info_set_procedures(PredInfo0, ProcTable, PredInfo),
		map__det_update(PredTable0, PredId, PredInfo, PredTable)
	;
			% Don't generate code in the current module for
			% unoptimized opt_imported preds
		Status = opt_imported
	->
		pred_info_procids(PredInfo0, ProcIds),
		pred_info_procedures(PredInfo0, ProcTable0),
			% Reduce memory usage by replacing the goals with 
			% conj([]).
		DestroyGoal =
			lambda([Id::in, PTable0::in, PTable::out] is det, (
				map__lookup(ProcTable0, Id, ProcInfo0),
				goal_info_init(GoalInfo),
				Goal = conj([]) - GoalInfo,
				proc_info_set_goal(ProcInfo0, Goal, ProcInfo),
				map__det_update(PTable0, Id, ProcInfo, PTable)
			)),
		list__foldl(DestroyGoal, ProcIds, ProcTable0, ProcTable),
		pred_info_set_procedures(PredInfo0, ProcTable, PredInfo1),
		pred_info_set_import_status(PredInfo1, imported, PredInfo),
		map__det_update(PredTable0, PredId, PredInfo, PredTable),
		globals__io_lookup_bool_option(very_verbose,
						VeryVerbose, State0, State1),
		( VeryVerbose = yes ->
			write_pred_progress_message(
				"% Eliminated opt_imported predicate ",
				PredId, ModuleInfo, State1, State)
		;
			State = State1
		)
	;
		State = State0,
		PredTable = PredTable0
	).

:- pred dead_proc_elim__eliminate_procs(pred_id, list(proc_id),
	needed_map, maybe(proc_id), string, int, module_info,
	proc_table, proc_table, io__state, io__state).
:- mode dead_proc_elim__eliminate_procs(in, in, in, in, in, in, in, in, out,
	di, uo) is det.

dead_proc_elim__eliminate_procs(_, [], _, _, _, _, _, ProcTable, ProcTable)
		--> [].
dead_proc_elim__eliminate_procs(PredId, [ProcId | ProcIds], Needed, Keep, Name,
		Arity, ModuleInfo, ProcTable0, ProcTable) -->
	(
		( { map__search(Needed, proc(PredId, ProcId), _) }
		; { Keep = yes(ProcId) }
		)
	->
		{ ProcTable1 = ProcTable0 }
	;
		globals__io_lookup_bool_option(very_verbose, VeryVerbose),
		( { VeryVerbose = yes } ->
			write_proc_progress_message(
				"% Eliminated the dead procedure ",
				PredId, ProcId, ModuleInfo)
		;
			[]
		),
		{ map__delete(ProcTable0, ProcId, ProcTable1) }
	),
	dead_proc_elim__eliminate_procs(PredId, ProcIds, Needed, Keep, Name,
		Arity, ModuleInfo, ProcTable1, ProcTable).

%-----------------------------------------------------------------------------%
