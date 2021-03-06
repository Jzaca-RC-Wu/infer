(*
 * Copyright (c) 2017 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! IStd
module F = Format
module L = Logging
open AbstractDomain.Types

module Summary = Summary.Make (struct
  type payload = CostDomain.summary

  let update_payload sum (summary: Specs.summary) =
    {summary with payload= {summary.payload with cost= Some sum}}


  let read_payload (summary: Specs.summary) = summary.payload.cost
end)

(* We use this treshold to give error if the cost is above it.
   Currently it's set randomly to 200. *)
let expensive_threshold = CostDomain.Cost.nth 200

(* CFG module used in several other modules  *)
module CFG = ProcCfg.Normal

(* Transfer function computing the semantics of the program.
   Here semantics means: for each node a pair (env, alias) where
   1. env is an 'environment', i.e. a map from variables to values
   2  alias is an alias map.
*)
module TransferFunctionsSemantics (CFG : ProcCfg.S) = struct
  module CFG = CFG
  module Domain = CostDomain.SemanticDomain

  let _exec_instr ((env, alias) as astate: Domain.astate) {ProcData.tenv} _ instr =
    let astate' =
      match instr with
      | Sil.Store (lhs, {Typ.desc= Tint _}, rhs, _) ->
          let env' = CostDomain.SemanticDomain.update_env env lhs rhs in
          let alias' = CostDomain.SemanticDomain.update_alias tenv alias lhs rhs in
          (env', alias')
      | Sil.Load (id, rhs, {Typ.desc= Tint _}, _) ->
          let env' = CostDomain.SemanticDomain.update_env env (Exp.Var id) rhs in
          let alias' = CostDomain.SemanticDomain.update_alias tenv alias (Exp.Var id) rhs in
          (env', alias')
      | Sil.Prune (e, _, _, _) -> (
        match CostDomain.SemanticDomain.sem env e with
        | Some e', Some v ->
            L.(debug Analysis Medium) "@\n e'= %a, v=%a @\n" Exp.pp e' CostDomain.ItvPureCost.pp v ;
            let v' =
              match CostDomain.EnvDomain.find_opt e' env with
              | Some v_pre ->
                  L.(debug Analysis Medium) "@\n>>>Starting meet 2 \n" ;
                  let meet = CostDomain.ItvPureCost.meet v_pre v in
                  L.(debug Analysis Medium)
                    "@\n>>> Result Meet v_pre= %a   e_val= %a --> %a\n" CostDomain.ItvPureCost.pp
                    v_pre CostDomain.ItvPureCost.pp v CostDomain.ItvPureCost.pp meet ;
                  if CostDomain.ItvPureCost.is_empty meet then v else meet
              | None ->
                  v
            in
            let env' = CostDomain.EnvDomain.add e' v' env in
            L.(debug Analysis Medium)
              "@\n e'= %a, v'=%a @\n" Exp.pp e' CostDomain.ItvPureCost.pp v' ;
            let env'' = CostDomain.SemanticDomain.update_alias_env env' alias e' in
            (env'', alias)
        | _ ->
            (env, alias) )
      | Sil.Load _
      | Sil.Store _
      | Sil.Call _
      | Sil.Declare_locals _
      | Remove_temps _
      | Abstract _
      | Nullify _ ->
          astate
    in
    astate'
end

(* Map associating to each node a bound on the number of times it can be executed.
   This bound is computed using environments (map: val -> values), using the following
   observation: the number of environments associated with a program point is an upperbound
   of the number of times the program point can be executed in any execution.
   The size of an environment env is computed as:
     |env| = |env(v1)| * ... * |env(n_k)|

   where |env(v)| is the size of the interval associated to v by env.

    Reference: see Stefan Bygde PhD thesis, 2010

*)
module BoundMap = struct
  let bound_map : CostDomain.Cost.astate Int.Map.t ref = ref Int.Map.empty

  let print_upper_bound_map () =
    L.(debug Analysis Medium) "@\n\n******* Bound Map **** @\n" ;
    Int.Map.iteri !bound_map ~f:(fun ~key:nid ~data:b ->
        L.(debug Analysis Medium) "@\n node: %i --> bound = %a @\n" nid CostDomain.Cost.pp b ) ;
    L.(debug Analysis Medium) "@\n******* END Bound Map **** @\n\n"


  let convert (mem: BufferOverrunDomain.Mem.astate) : CostDomain.EnvDomainBO.astate =
    let open AbstractDomain.Types in
    match mem with
    | Bottom ->
        assert false
    | NonBottom {BufferOverrunDomain.MemReach.heap} ->
        let env =
          BufferOverrunDomain.Heap.fold
            (fun loc data acc ->
              match loc with
              | AbsLoc.Loc.Var Var.LogicalVar id ->
                  let key = Exp.Var id in
                  CostDomain.EnvDomain.add key (BufferOverrunDomain.Val.get_itv data) acc
              | AbsLoc.Loc.Var Var.ProgramVar v ->
                  let key = Exp.Lvar v in
                  CostDomain.EnvDomain.add key (BufferOverrunDomain.Val.get_itv data) acc
              | _ ->
                  acc )
            heap CostDomain.EnvDomainBO.empty
        in
        env


  let compute_upperbound_map cfg invariant_map =
    let range itv =
      let rng = Itv._range itv in
      match Itv.Bound.is_const rng with
      | Some r ->
          CostDomain.Cost.nth r
      | _ ->
          (* TODO: write code for the non constant case *)
          L.(debug Analysis Medium)
            "@\n [Range computation]: Can't determine a range for itv = %a. Returning Top@\n"
            Itv.Bound.pp rng ;
          Top
    in
    let compute_node_upper_bound node =
      let node_id = Procdesc.Node.get_id node in
      let entry_mem_opt = BufferOverrunChecker.extract_post invariant_map node in
      match Procdesc.Node.get_kind node with
      | Procdesc.Node.Exit_node _ ->
          bound_map := Int.Map.set !bound_map ~key:(node_id :> int) ~data:CostDomain.Cost.one
      | _ ->
        match entry_mem_opt with
        | Some entry_mem ->
            let env = convert entry_mem in
            (* bound = env(v1) *... * env(vn) *)
            let bound =
              CostDomain.EnvDomainBO.fold
                (fun exp itv acc ->
                  let itv' =
                    match exp with
                    | Exp.Lvar _ ->
                        itv
                    | Exp.Var _ ->
                        Itv.one
                    (* For temp var we give [1,1] so it doesn't count*)
                    | _ ->
                        assert false
                  in
                  let itv_range = range itv' in
                  L.(debug Analysis Medium)
                    "@\n>>>For node = %i :   itv=%a  range=%a  @\n\n"
                    (node_id :> int)
                    Itv.pp itv' CostDomain.Cost.pp itv_range ;
                  CostDomain.Cost.mult acc itv_range )
                env CostDomain.Cost.one
            in
            L.(debug Analysis Medium)
              "@\n>>>Setting bound for node = %i  to %a@\n\n"
              (node_id :> int)
              CostDomain.Cost.pp bound ;
            bound_map := Int.Map.set !bound_map ~key:(node_id :> int) ~data:bound
        | _ ->
            bound_map := Int.Map.set !bound_map ~key:(node_id :> int) ~data:CostDomain.Cost.zero
    in
    List.iter (CFG.nodes cfg) ~f:compute_node_upper_bound ;
    print_upper_bound_map ()


  let upperbound nid =
    match Int.Map.find !bound_map nid with
    | Some bound ->
        bound
    | None ->
        L.(debug Analysis Medium)
          "@\n\n[WARNING] Bound not found for node %i, returning Top @\n" nid ;
        Top
end

(* Structural Constraints are expressions of the kind:
     n <= n1 +...+ nk

   The informal meaning is: the number of times node n can be executed is less or
   equal to the sum of the number of times nodes n1,..., nk can be executed.
*)
module StructuralConstraints = struct
  let print_constraint_list constraints =
    L.(debug Analysis Medium) "@\n\n******* Structural Constraints **** @\n" ;
    List.iter ~f:(fun c -> L.(debug Analysis Medium) "@\n    %a   @\n" Exp.pp c) constraints ;
    L.(debug Analysis Medium) "@\n******* END Structural Constraints **** @\n\n"


  (*  for each program point return a set of contraints of the kind

     i<=Sum_{j \in Predecessors(i) } j
     i<=Sum_{j \in Successors(i)} j
*)
  let compute_structural_constraints cfg =
    let exp_nid n =
      let nid = (Procdesc.Node.get_id n :> int) in
      Exp.Const (Cint (IntLit.of_int nid))
    in
    let rec exp_sum nodes =
      match nodes with
      | [] ->
          assert false (* this cannot happen here *)
      | [n] ->
          exp_nid n
      | n :: nodes' ->
          let sum_nodes' = exp_sum nodes' in
          Exp.BinOp (Binop.PlusA, exp_nid n, sum_nodes')
    in
    let compute_node_constraints acc node =
      let constrants_preds_succs gets_preds_succs =
        match gets_preds_succs node with
        | [] ->
            []
        | res_nodes ->
            [Exp.BinOp (Binop.Le, exp_nid node, exp_sum res_nodes)]
      in
      let preds_con = constrants_preds_succs Procdesc.Node.get_preds in
      let succs_con = constrants_preds_succs Procdesc.Node.get_succs in
      preds_con @ succs_con @ acc
    in
    let constraints = List.fold (CFG.nodes cfg) ~f:compute_node_constraints ~init:[] in
    print_constraint_list constraints ; constraints
end

(* MinTree is used to compute:

    \max (\Sum_{n \in Nodes} c_n * x_n )

   given a set of contraints on x_n. The constraints involve the contro flow
    of the program.

*)
module MinTree = struct
  type mt_node =
    | Leaf of (int * CostDomain.Cost.astate)
    | Min of mt_node list
    | Plus of mt_node list

  let add_leaf node nid leaf =
    let leaf' = Leaf (nid, leaf) in
    match node with Min l -> Min (leaf' :: l) | Plus l -> Plus (leaf' :: l) | _ -> assert false


  let plus_seq pp f l = Pp.seq ~sep:" + " pp f l

  let rec pp fmt node =
    match node with
    | Leaf (nid, c) ->
        F.fprintf fmt "%i:%a" nid CostDomain.Cost.pp c
    | Min l ->
        F.fprintf fmt "Min(%a)" (Pp.comma_seq pp) l
    | Plus l ->
        F.fprintf fmt "(%a)" (plus_seq pp) l


  let add_child node child =
    match child with
    | Plus [] | Min [] ->
        node (* if it's a dummy child, don't add it *)
    | _ ->
      match node with Plus l -> Plus (child :: l) | Min l -> Min (child :: l) | _ -> assert false


  (* finds the subset of constraints of the form x_k <= x_j *)
  let get_k_single_constraints constraints k =
    List.filter_map
      ~f:(fun c ->
        match c with
        (* constraint x_k <= x_j is represented by k<=j *)
        | Exp.BinOp (Binop.Le, Exp.Const Cint k', Exp.Const Cint nid)
          when Int.equal k (IntLit.to_int k') ->
            Some (IntLit.to_int nid)
        | _ ->
            None )
      constraints


  (* finds the subset of constraints of the form x_k <= x_j1 +...+ x_jn and
return the addends of the sum x_j1+x_j2+..+x_j_n*)
  let get_k_sum_constraints constraints k =
    let rec addends e =
      match e with
      | Exp.Const Cint nid ->
          Int.Set.singleton (IntLit.to_int nid)
      | Exp.BinOp (Binop.PlusA, e1, e2) ->
          Int.Set.union (addends e1) (addends e2)
      | _ ->
          assert false
    in
    List.filter_map
      ~f:(fun c ->
        match c with
        | Exp.BinOp (Binop.Le, Exp.Const Cint k', (Exp.BinOp (Binop.PlusA, _, _) as sum_exp))
          when Int.equal k (IntLit.to_int k') ->
            Some (addends sum_exp)
        | _ ->
            None )
      constraints


  let rec evaluate_tree t =
    match t with
    | Leaf (_, c) ->
        c
    | Min l ->
        evaluate_operator CostDomain.Cost.min l
    | Plus l ->
        evaluate_operator CostDomain.Cost.plus l


  and evaluate_operator op l =
    match l with
    | [] ->
        assert false
    | [c] ->
        evaluate_tree c
    | c :: l' ->
        let res_c = evaluate_tree c in
        let res_l' = evaluate_operator op l' in
        op res_c res_l'


  (* TO DO: replace equality on sets with something more efficient*)
  let rec add_without_rep s list_of_sets =
    match list_of_sets with
    | [] ->
        [s]
    | s' :: tail ->
        if Int.Set.equal s s' then list_of_sets else s' :: add_without_rep s tail


  (*  a plus node is well formed if has at least two addends *)
  let is_well_formed_plus_node plus_node =
    match plus_node with Plus (_ :: _ :: _) -> true | _ -> false


  (* TO DO: rewrite in a functional way rather than imperative T26418766 *)
  let rec minimum_propagation (q: int) (visited: Int.Set.t) (constraints: Exp.t list) =
    let node = ref (Min []) in
    let worklist : int Stack.t = Stack.create () in
    Stack.push worklist q ;
    let branch = ref [] in
    let visited_acc = ref visited in
    while not (Stack.is_empty worklist) do
      let k =
        match Stack.pop worklist with Some k' -> k' | None -> assert false
        (* we cant be here *)
      in
      if Int.Set.mem !visited_acc k then ()
      else (
        visited_acc := Int.Set.add !visited_acc k ;
        node := add_leaf !node k (BoundMap.upperbound k) ;
        let k_constraints_upperbound = get_k_single_constraints constraints k in
        List.iter
          ~f:(fun ub_id -> if not (Int.Set.mem !visited_acc ub_id) then Stack.push worklist ub_id)
          k_constraints_upperbound ;
        let k_sum_constraints = get_k_sum_constraints constraints k in
        List.iter
          ~f:(fun set_addend ->
            if Int.Set.is_empty (Int.Set.inter set_addend !visited_acc) then
              branch := add_without_rep set_addend !branch )
          k_sum_constraints )
    done ;
    List.iter
      ~f:(fun addend ->
        if Int.Set.length addend < 2 then assert false
        else (
          L.(debug Analysis Medium) "@\n\n|Set addends| = %i  {" (Int.Set.length addend) ;
          Int.Set.iter ~f:(fun e -> L.(debug Analysis Medium) " %i, " e) addend ;
          L.(debug Analysis Medium) " }@\n " ) ;
        let plus_node =
          Set.fold
            ~f:(fun acc n ->
              let child = minimum_propagation n !visited_acc constraints in
              add_child acc child )
            ~init:(Plus []) addend
        in
        (* without this check it would add plus node with just one child, and give wrong results *)
        if is_well_formed_plus_node plus_node then node := add_child !node plus_node )
      !branch ;
    !node


  let compute_trees_from_contraints cfg constraints =
    let min_trees =
      List.fold
        ~f:(fun acc n ->
          let nid = (Procdesc.Node.get_id n :> int) in
          (nid, minimum_propagation nid Int.Set.empty constraints) :: acc )
        ~init:[] (CFG.nodes cfg)
    in
    List.iter ~f:(fun (n, t) -> L.(debug Analysis Medium) "@\n node %i = %a @\n" n pp t) min_trees ;
    min_trees
end

(* Compute a map (node,instruction) -> basic_cost, where basic_cost is the
   cost known for a certain operation. For example for basic operation we
   set it to 1 and for function call we take it from the spec of the function.
   The nodes in the domain of the map are those in the path reaching the current node.
*)
module TransferFunctionsNodesBasicCost (CFG : ProcCfg.S) = struct
  module CFG = CFG
  module Domain = CostDomain.NodeInstructionToCostMap

  type extras = ProcData.no_extras

  let cost_atomic_instruction = CostDomain.Cost.one

  let instr_idx (node: CFG.node) instr =
    match CFG.instrs node with
    | [] ->
        0
    | instrs ->
        List.find_mapi_exn
          ~f:(fun idx i -> if Sil.equal_instr i instr then Some idx else None)
          instrs


  let exec_instr (astate: Domain.astate) {ProcData.pdesc} (node: CFG.node) instr : Domain.astate =
    let nid_int = (Procdesc.Node.get_id (CFG.underlying_node node) :> int) in
    let instr_idx = instr_idx node instr in
    let key = (nid_int, instr_idx) in
    let astate' =
      match instr with
      | Sil.Call (_, Exp.Const Const.Cfun callee_pname, _, _, _) -> (
        match Summary.read_summary pdesc callee_pname with
        | Some {post= cost_callee} ->
            Domain.add key cost_callee astate
        | None ->
            Domain.add key cost_atomic_instruction astate )
      | Sil.Load _ | Sil.Store _ | Sil.Call _ | Sil.Prune _ ->
          Domain.add key cost_atomic_instruction astate
      | _ ->
          astate
    in
    L.(debug Analysis Medium)
      "@\n>>>Instr: %a   Cost: %a@\n" (Sil.pp_instr Pp.text) instr Domain.pp astate' ;
    astate'
end

module AnalyzerNodesBasicCost = AbstractInterpreter.Make (CFG) (TransferFunctionsNodesBasicCost)
module RepSet = AbstractDomain.FiniteSet (Int)

(* Calculate the final Worst Case Execution Time predicted for each node.
   It uses the basic cost of the nodes (computed previously by AnalyzerNodesBasicCost)
   and MinTrees which give an upperbound on the number of times a node can be executed
*)
module TransferFunctionsWCET (CFG : ProcCfg.S) = struct
  module CFG = CFG
  module CSI = CostDomain.CostSingleIteration
  module Domain = AbstractDomain.Pair (CSI) (RepSet)

  type extras =
    (* extras: (map with basic costs, min trees map, summary ) *)
    AnalyzerNodesBasicCost.invariant_map * CostDomain.Cost.astate Int.Map.t * Specs.summary

  let report_cost summary instr cost nid reported_so_far =
    match cost with
    | Top ->
        (cost, reported_so_far)
        (* We don't report when the cost Top as it corresponds to 'don't know'*)
    | _ ->
        let above_expensive_threshold = not (CSI.( <= ) ~lhs:cost ~rhs:expensive_threshold) in
        match instr with
        | Sil.Call (_, _, _, loc, _) when above_expensive_threshold ->
            let ltr = [Errlog.make_trace_element 0 loc "" []] in
            let message =
              F.asprintf
                "This instruction is expensive (estimated cost %a). Its execution time is likely \
                 above the acceptable treshold " CSI.pp cost
            in
            let exn =
              Exceptions.Checkers
                (IssueType.expensive_execution_time_call, Localise.verbatim_desc message)
            in
            Reporting.log_error summary ~loc ~ltr exn ;
            (cost, RepSet.add nid reported_so_far)
        | Sil.Load (_, _, _, loc)
        | Sil.Store (_, _, _, loc)
        | Sil.Call (_, _, _, loc, _)
        | Sil.Prune (_, loc, _, _)
          when above_expensive_threshold ->
            let ltr = [Errlog.make_trace_element 0 loc "" []] in
            let message =
              F.asprintf
                "The execution time from the beginning of the function is above the acceptable \
                 treshold (estimated cost %a up to here)" CSI.pp cost
            in
            let exn =
              Exceptions.Checkers
                (IssueType.expensive_execution_time_call, Localise.verbatim_desc message)
            in
            Reporting.log_error summary ~loc ~ltr exn ;
            (cost, RepSet.add nid reported_so_far)
        | _ ->
            (cost, reported_so_far)


  (* get a list of nodes and check if we have already reported for at
   least one of them. In that case no need to report again. *)
  let should_report preds reported_so_far =
    List.for_all
      ~f:(fun n ->
        let n_id = (Procdesc.Node.get_id n :> int) in
        not (RepSet.mem n_id reported_so_far) )
      preds


  let exec_instr (astate: Domain.astate) {ProcData.extras} (node: CFG.node) instr : Domain.astate =
    let invariant_map_cost, trees, summary = extras in
    let und_node = CFG.underlying_node node in
    let node_id = Procdesc.Node.get_id und_node in
    let preds = Procdesc.Node.get_preds und_node in
    let map_cost m : CSI.astate =
      CostDomain.NodeInstructionToCostMap.fold
        (fun (nid, idx) c acc ->
          match Int.Map.find trees nid with
          | Some t ->
              let c_node = CSI.mult c t in
              L.(debug Analysis Medium)
                "@\n  [AnalizerWCTE] Adding cost: (%i,%i) --> c =%a  t = %a @\n" nid idx CSI.pp c
                CSI.pp t ;
              let c_node' = CSI.plus acc c_node in
              L.(debug Analysis Medium)
                "@\n  [AnalizerWCTE] Adding cost: (%i,%i) --> c_node=%a  cost = %a @\n" nid idx
                CSI.pp c_node CSI.pp c_node' ;
              c_node'
          | _ ->
              assert false )
        m CSI.zero
    in
    let cost_node =
      match AnalyzerNodesBasicCost.extract_post node_id invariant_map_cost with
      | Some node_map ->
          L.(debug Analysis Medium)
            "@\n AnalizerWCTE] Final map for node: %a @\n" Procdesc.Node.pp_id node_id ;
          map_cost node_map
      | _ ->
          assert false
    in
    L.(debug Analysis Medium)
      "@\n>>>AnalizerWCTE] Instr: %a   Cost: %a@\n" (Sil.pp_instr Pp.text) instr CSI.pp cost_node ;
    let reported_so_far = snd astate in
    let astate' =
      if should_report (und_node :: preds) reported_so_far then
        report_cost summary instr cost_node (node_id :> int) reported_so_far
      else (cost_node, reported_so_far)
    in
    astate'
end

module AnalyzerWCET = AbstractInterpreter.Make (CFG) (TransferFunctionsWCET)

let checker ({Callbacks.tenv; summary; proc_desc} as proc_callback_args) : Specs.summary =
  let cfg = CFG.from_pdesc proc_desc in
  (* computes the semantics: node -> (environment, alias map) *)
  let semantics_invariant_map = BufferOverrunChecker.compute_invariant_map proc_callback_args in
  (* given the semantics computes the upper bound on the number of times a node could be executed *)
  BoundMap.compute_upperbound_map cfg semantics_invariant_map ;
  let constraints = StructuralConstraints.compute_structural_constraints cfg in
  let min_trees = MinTree.compute_trees_from_contraints cfg constraints in
  let trees_valuation =
    List.fold
      ~f:(fun acc (n, t) ->
        let res = MinTree.evaluate_tree t in
        L.(debug Analysis Medium) "@\n   Tree %i eval to %a @\n" n CostDomain.Cost.pp res ;
        Int.Map.set acc ~key:n ~data:res )
      ~init:Int.Map.empty min_trees
  in
  let invariant_map_NodesBasicCost =
    (*compute_WCET cfg invariant_map min_trees in *)
    AnalyzerNodesBasicCost.exec_cfg cfg
      (ProcData.make_default proc_desc tenv)
      ~initial:CostDomain.NodeInstructionToCostMap.empty ~debug:true
  in
  let initWCET = (CostDomain.CostSingleIteration.zero, RepSet.empty) in
  let invariant_map_WCETFinal =
    (* Final map with nodes cost *)
    AnalyzerWCET.exec_cfg cfg
      (ProcData.make proc_desc tenv (invariant_map_NodesBasicCost, trees_valuation, summary))
      ~initial:initWCET ~debug:true
  in
  match AnalyzerWCET.extract_post (CFG.id (CFG.exit_node cfg)) invariant_map_WCETFinal with
  | Some (exit_cost, _) ->
      Summary.update_summary {post= exit_cost} summary
  | None ->
      if Procdesc.Node.get_succs (Procdesc.get_start_node proc_desc) <> [] then (
        L.internal_error "Failed to compute final cost for function %a" Typ.Procname.pp
          (Procdesc.get_proc_name proc_desc) ;
        summary )
      else summary
