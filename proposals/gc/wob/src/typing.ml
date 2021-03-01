open Source
open Syntax

module T = Type


(* Error handling *)

exception Error of Source.region * string

let error at fmt = Printf.ksprintf (fun s -> raise (Error (at, s))) fmt


(* Environments *)

type env = (T.sort * T.typ, T.kind * T.con) Env.env

module E =
struct
  include Env
  let extend_val_let env x t = extend_val env x (T.LetS, t)
  let extend_vals_let env xs ts =
    extend_vals env xs (List.map (fun t -> (T.LetS, t)) ts)
  let extend_typ_abs env y = extend_typ env y (0, fun _ -> T.var y)
  let extend_typs_abs env ys = List.fold_left extend_typ_abs env ys
end


(* Types *)

let check_typ_var env y : T.kind * T.con =
  match E.find_typ y.it env with
  | Some kc -> kc
  | None -> error y.at "unknown type identifier `%s`" y.it


let rec check_typ env t : T.typ =
  let t' = check_typ' env t in
  t.et <- Some t';
  t'

and check_typ' (env : env) t : T.typ =
  match t.it with
  | VarT (y, ts) ->
    let k, c = check_typ_var env y in
    if List.length ts <> k then
      error t.at "wrong number of type arguments at type use";
    c (List.map (check_typ env) ts)
  | BoolT -> T.Bool
  | ByteT -> T.Byte
  | IntT -> T.Int
  | FloatT -> T.Float
  | TextT -> T.Text
  | ObjT -> T.Obj
  | TupT ts -> T.Tup (List.map (check_typ env) ts)
  | ArrayT t -> T.Array (check_typ env t)
  | FuncT (ys, ts1, ts2) ->
    let ys' = List.map Source.it ys in
    let env' = E.extend_typs_abs env ys' in
    T.Func (ys', List.map (check_typ env') ts1, List.map (check_typ env') ts2)


(* Expressions *)

let check_var_sort env x : T.sort * T.typ =
  match E.find_val x.it env with
  | Some sv -> sv
  | None -> error x.at "unknown value identifier `%s`" x.it

let check_var env x : T.typ =
  snd (check_var_sort env x)


let check_lit _env lit : T.typ =
  match lit with
  | NullLit -> T.Null
  | BoolLit _ -> T.Bool
  | IntLit _ -> T.Int
  | FloatLit _ -> T.Float
  | TextLit _ -> T.Text


let rec check_exp env e : T.typ =
  let t = check_exp' env e in
  e.et <- Some t;
  t

and check_exp' env e : T.typ =
  match e.it with
  | VarE x ->
    check_var env x

  | LitE l ->
    check_lit env l

  | UnE (op, e1) ->
    let t1 = check_exp env e1 in
    (match op, t1 with
    | (PosOp | NegOp), T.Int -> T.Int
    | (PosOp | NegOp), T.Float -> T.Float
    | NotOp, T.Bool -> T.Bool
    | _ ->
      error e.at "unary operator not defined for type %s"
        (T.to_string t1)
    )

  | BinE (e1, op, e2) ->
    let t1 = check_exp env e1 in
    let t2 = check_exp env e2 in
    let t = try T.lub t1 t2 with Failure _ ->
      error e.at "binary operator applied to incompatible types %s and %s"
        (T.to_string t1) (T.to_string t2)
    in
    (match op, t with
    | (AddOp | SubOp | MulOp | DivOp | ModOp), T.Int -> T.Int
    | (AddOp | SubOp | MulOp | DivOp), T.Float -> T.Float
    | (AndOp | OrOp), T.Bool -> T.Bool
    | CatOp, T.Text -> T.Text
    | _ ->
      error e.at "binary operator not defined for types %s and %s"
        (T.to_string t1) (T.to_string t2)
    )

  | RelE (e1, op, e2) ->
    let t1 = check_exp env e1 in
    let t2 = check_exp env e2 in
    let t = try T.lub t1 t2 with Failure _ ->
      error e.at "comparison operator applied to incompatible types %s and %s"
        (T.to_string t1) (T.to_string t2)
    in
    (match op, t with
    | (EqOp | NeOp), (T.Null | T.Bool | T.Obj | T.Array _ | T.Inst _)
    | (EqOp | NeOp | LtOp | GtOp | LeOp | GeOp), (T.Byte | T.Int | T.Float) ->
      T.Bool
    | _ ->
      error e.at "comparison operator not defined for types %s and %s"
        (T.to_string t1) (T.to_string t2)
    )

  | TupE es ->
    let ts = List.map (check_exp env) es in
    T.Tup ts

  | ProjE (e1, n) ->
    let t1 = check_exp env e1 in
    (match t1 with
    | T.Tup ts when n < List.length ts -> List.nth ts n
    | T.Tup _ -> error e.at "wrong number of tuple components"
    | _ -> error e.at "tuple type expected but got %s" (T.to_string t1)
    )

  | ArrayE es ->
    let ts = List.map (check_exp env) es in
    let t =
      match ts with
      | [] -> T.Null (*TODO*)
      | t::ts' ->
        try List.fold_left T.lub t ts' with Failure _ ->
          error e.at "array has inconsistent element types"
    in
    T.Array t

  | IdxE (e1, e2) ->
    let t1 = check_exp env e1 in
    let t2 = check_exp env e2 in
    (match t1, t2 with
    | T.Text, T.Int -> T.Byte
    | T.Array t, T.Int -> t
    | T.Array t, _ ->
      error e2.at "integer type expected but got %s" (T.to_string t2)
    | _ -> error e1.at "array type expected but got %s" (T.to_string t1)
    )

  | CallE (e1, ts, es) ->
    let t1 = check_exp env e1 in
    let ts' = List.map (check_typ env) ts in
    (match t1 with
    | T.Func (ys, ts1, ts2) ->
      if List.length ts' <> List.length ys then
        error e1.at "wrong number of type arguments at function call";
      if List.length es <> List.length ts1 then
        error e1.at "wrong number of arguments at function call";
      let s = T.typ_subst ys ts' in
      let ts1' = List.map (T.subst s) ts1 in
      let ts2' = List.map (T.subst s) ts2 in
      List.iter2 (fun eI tI ->
        let tI' = check_exp env eI in
        if not (T.sub tI' tI) then
          error eI.at "function expects argument type %s but got %s"
            (T.to_string tI) (T.to_string tI')
      ) es ts1';
      (match ts2' with [t2] -> t2 | _ -> T.Tup ts2')
    | _ -> error e1.at "function type expected but got %s" (T.to_string t1)
    )

  | NewE (x, ts, es) ->
    let t1 = check_var env x in
    let ts' = List.map (check_typ env) ts in
    (match t1 with
    | T.Class cls ->
      if List.length ts' <> List.length cls.T.tparams then
        error x.at "wrong number of type arguments at class instantiation";
      if List.length es <> List.length cls.T.vparams then
        error x.at "wrong number of arguments at class instantiation";
      let s = T.typ_subst cls.T.tparams ts' in
      let ts1' = List.map (T.subst s) cls.T.vparams in
      List.iter2 (fun eI tI ->
        let tI' = check_exp env eI in
        if not (T.sub tI' tI) then
          error eI.at "class expects argument type %s but got %s"
            (T.to_string tI) (T.to_string tI')
      ) es ts1';
      T.Inst (cls, ts')
    | _ -> error x.at "class type expected but got %s" (T.to_string t1)
    )

  | NewArrayE (t, e1, e2) ->
    let t' = check_typ env t in
    let t1 = check_exp env e1 in
    let t2 = check_exp env e2 in
    if not (T.sub t1 T.Int) then
      error e1.at "integer type expected but got %s" (T.to_string t1);
    if not (T.sub t2 t') then
      error e2.at "array initialization expects argument type %s but got %s"
        (T.to_string t') (T.to_string t2);
    T.Array t'

  | DotE (e1, x) ->
    let t1 = check_exp env e1 in
    (match t1 with
    | T.Inst (cls, ts) ->
      (match E.Map.find_opt x.it cls.T.def with
      | Some (s, t) -> T.subst (T.typ_subst cls.T.tparams ts) t
      | None -> error e1.at "unknown field `%s`" x.it
      )
    | _ -> error e1.at "object type expected but got %s" (T.to_string t1)
    )

  | AssignE (e1, e2) ->
    let t1 = check_exp_ref env e1 in
    let t2 = check_exp env e2 in
    if not (T.sub t2 t1) then
      error e1.at "assigment expects type %s but got %s"
        (T.to_string t1) (T.to_string t2);
    T.Tup []

  | AnnotE (e1, t) ->
    let t1 = check_exp env e1 in
    let t2 = check_typ env t in
    if not (T.sub t1 t2) then
      error e1.at "annotation expects type %s but got %s"
        (T.to_string t2) (T.to_string t2);
    t2

  | CastE (e1, t) ->
    let t1 = check_exp env e1 in
    let t2 = check_typ env t in
    if not (T.sub t1 T.Obj) then
      error e1.at "object type expected but got %s" (T.to_string t1);
    if not (T.sub t2 T.Obj) then
      error t.at "object type expected as cast target";
    t2

  | AssertE e1 ->
    let t1 = check_exp env e1 in
    if not (T.sub t1 T.Bool) then
      error e1.at "boolean type expected but got %s" (T.to_string t1);
    T.Tup []

  | IfE (e1, e2, e3) ->
    let t1 = check_exp env e1 in
    let t2 = check_exp env e2 in
    let t3 = check_exp env e3 in
    if not (T.sub t1 T.Bool) then
      error e1.at "boolean type expected but got %s" (T.to_string t1);
    let t = try T.lub t2 t3 with Failure _ ->
      error e.at "coniditional branches have incompatible types %s and %s"
        (T.to_string t2) (T.to_string t3)
    in t

  | WhileE (e1, e2) ->
    let t1 = check_exp env e1 in
    let _t2 = check_exp env e2 in
    if not (T.sub t1 T.Bool) then
      error e1.at "boolean type expected but got %s" (T.to_string t1);
    T.Tup []

  | RetE es ->
    let ts = List.map (check_exp env) es in
    (match E.find_val "return" env with
    | None -> error e.at "misplaced return"
    | Some (_, t) ->
      if not (T.sub (T.Tup ts) t) then
        error e.at "return expects type %s but got %s"
          (T.to_string t) (T.to_string (T.Tup ts));
    );
    (match ts with [t] -> t | _ -> T.Tup ts)

  | BlockE ds ->
    fst (check_decs env ds (T.Tup []))


and check_exp_ref env e : T.typ =
  let t = check_exp env e in
  (match e.it with
  | VarE x ->
    let s, _ = check_var_sort env x in
    if s <> T.VarS then
      error e.at "mutable variable expected"

  | IdxE (e1, _) ->
    (match e1.et with
    | Some (T.Array _) -> ()
    | _ -> error e.at "mutable array expected"
    )

  | DotE (e1, x) ->
    (match e1.et with
    | Some (T.Inst (cls, _)) ->
      let s, _ = E.Map.find x.it cls.T.def in
      if s <> T.VarS then
        error x.at "mutable field expected"
    | _ -> error x.at "mutable field expected"
    )

  | _ -> error e.at "invalid assignment target"
  );
  t


(* Declarations *)

and check_dec env d : T.typ * env =
  match d.it with
  | ExpD e ->
    let t = check_exp env e in
    t, E.empty

  | LetD (x, e) ->
    let t = check_exp env e in
    T.Tup [], E.singleton_val x.it (T.LetS, t)

  | VarD (x, e) ->
    let t = check_exp env e in
    T.Tup [], E.singleton_val x.it (T.VarS, t)

  | TypD (y, ys, t) ->
    let ys' = List.map it ys in
    let env' = E.extend_typs_abs env ys' in
    let t' = check_typ env' t in
    let con ts = T.subst (T.typ_subst ys' ts) t' in
    T.Tup [], E.singleton_typ y.it (List.length ys, con)

  | FuncD (x, ys, xts, ts, e) ->
    let ys' = List.map it ys in
    let env' = E.extend_typs_abs env ys' in
    let ts1 = List.map (check_typ env') (List.map snd xts) in
    let ts2 = List.map (check_typ env') ts in
    let xs1 = List.map it (List.map fst xts) in
    let t = T.Func (ys', ts1, ts2) in
    let env'' = E.extend_val env' x.it (T.FuncS, t) in
    let env'' = E.extend_vals_let env'' xs1 ts1 in
    let env'' = E.extend_val_let env'' "return" (T.Tup ts2) in
    let t' = check_exp env'' e in
    let t2 = match ts2 with [t2] -> t2 | _ -> T.Tup ts2 in
    if not (T.sub t' t2) then
      error e.at "function expects return type %s but got %s"
        (T.to_string t2) (T.to_string t');
    T.Tup [], E.singleton_val x.it (T.FuncS, t)

  | ClassD (x, ys, xts, sup_opt, ds) ->
    let k = List.length ys in
    let ys' = List.map it ys in
    let cls = T.empty_class x.it ys' in
    let con ts = T.Inst (cls, ts) in
    let env' = E.extend_typ env x.it (k, con) in
    let env' = E.extend_typs_abs env' ys' in
    let ts1 = List.map (check_typ env') (List.map snd xts) in
    let xs1 = List.map it (List.map fst xts) in
    cls.T.vparams <- ts1;
    let t = T.Class cls in
    let env'' = E.extend_val env' x.it (T.ClassS, t) in
    let env'' = E.extend_vals_let env'' xs1 ts1 in
    (* TODO: handle `this` *)
    let obj' =
      match sup_opt with
      | None -> E.Map.empty
      | Some (x2, ts2, es2) ->
        let t' = check_typ env'' (VarT (x2, ts2) @@ x2.at) in
        cls.T.sup <- t';
        match check_exp env'' (NewE (x2, ts2, es2) @@ x2.at) with
        | T.Inst (cls, _) -> cls.T.def
        | _ -> assert false
    in
    let env''' = E.Map.fold (fun x v env -> Env.extend_val env x v) obj' env'' in
    (* Rebind local vars to shadow parent fields *)
    let env''' = E.extend_val env''' x.it (T.ClassS, t) in
    let env''' = E.extend_vals_let env''' xs1 ts1 in
    let _, oenv = check_decs env''' ds (T.Tup []) in
    cls.T.def <-
      E.Map.union (fun x (s', t') (s, t) ->
        if s' <> T.FuncS then
          error d.at "class overrides parent member `%s` that is not a function" x;
        if s <> T.FuncS then
          error d.at "class overrides parent member `%s` with a non-function" x;
        if not (T.sub t t') then
          error d.at "class overrides parent member `%s` of type %s with incompatible type %s"
            x (T.to_string t') (T.to_string t);
        Some (s, t)
      ) obj' oenv.E.vals;
    T.Tup [],
    E.adjoin (E.singleton_typ x.it (k, con)) (E.singleton_val x.it (T.ClassS, t))

  | ImportD (xs, url) ->
    (* TODO *)
    error d.at "imports not implemented yet"

and check_decs env ds v : T.typ * env =
  match ds with
  | [] -> v, E.empty
  | d::ds' ->
    let v', env' = check_dec env d in
    let v'', env'' = check_decs (E.adjoin env env') ds' v' in
    try v'', E.disjoint_union env' env'' with E.Clash x ->
      error d.at "duplicate definition for `%s`" x


(* Programs *)

let check_prog env (Prog ds) : T.typ * env =
  check_decs env ds (T.Tup [])
