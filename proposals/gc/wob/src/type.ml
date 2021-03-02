(* Types *)

type var = string
type kind = int
type sort = LetS | VarS | FuncS | ClassS | ProhibitedS

type typ =
  | Var of var * typ list
  | Null
  | Bool
  | Byte
  | Int
  | Float
  | Text
  | Obj
  | Tup of typ list
  | Array of typ
  | Func of var list * typ list * typ list
  | Inst of cls * typ list
  | Class of cls

and cls =
  { name : var;
    tparams : var list;
    mutable vparams : typ list;
    mutable sup : typ;
    mutable def : (sort * typ) Env.Map.t;
  }


(* Helpers *)

let var y = Var (y, [])


(* Printing *)

let list f xs = String.concat ", " (List.map f xs)

let rec to_string = function
  | Var (y, []) -> y
  | Var (y, ts) -> y ^ "<" ^ list to_string ts ^ ">" 
  | Null -> "Null"
  | Bool -> "Bool"
  | Byte -> "Byte"
  | Int -> "Int"
  | Float -> "Float"
  | Text -> "Text"
  | Obj -> "Object"
  | Tup ts -> "(" ^ list to_string ts ^ ")"
  | Array t -> to_string t ^ "[]"
  | Func ([], ts1, ts2) -> params ts1 ^ " -> " ^ params ts2
  | Func (ys, ts1, ts2) ->
    "<" ^ list Fun.id ys ^ ">(" ^ params ts1 ^ ") -> " ^ params ts2
  | Inst (c, ts) -> to_string (Var (c.name, ts))
  | Class c -> "class " ^ c.name

and params = function
  | [t] -> to_string t
  | ts -> "(" ^ list to_string ts ^ ")"


(* Substitutions *)

module Subst = Env.Map

type con = typ list -> typ
type subst = con Subst.t

let empty_subst = Subst.empty
let adjoin_subst s1 s2 = Subst.union (fun _ y1 y2 -> Some y2) s1 s2

let lookup_subst s y = Subst.find_opt y s
let extend_subst s y c = Subst.add y c s
let extend_subst_typ s y t = extend_subst s y (fun _ -> t)
let extend_subst_abs s y = extend_subst_typ s y (var y)

let typ_subst ys ts = List.fold_left2 extend_subst_typ empty_subst ys ts


let fresh_cnts = ref Env.Map.empty

let fresh y =
  let i =
    match Env.Map.find_opt y !fresh_cnts with
    | None -> 1
    | Some i -> i + 1
  in
  fresh_cnts := Env.Map.add y i !fresh_cnts;
  y ^ "-" ^ string_of_int i


let rec subst s t =
  if Subst.is_empty s then t else
  match t with
  | Var (y, ts) when Subst.mem y s -> Subst.find y s (List.map (subst s) ts)
  | Var (y, ts) -> Var (y, List.map (subst s) ts)
  | Tup ts -> Tup (List.map (subst s) ts)
  | Array t -> Array (subst s t)
  | Func (ys, ts1, ts2) ->
    let ys' = List.map fresh ys in
    let s' = adjoin_subst s (typ_subst ys (List.map var ys')) in
    Func (ys', List.map (subst s') ts1, List.map (subst s') ts2)
  | Inst (c, ts) -> Inst (subst_cls s c, List.map (subst s) ts)
  | Class c -> Class (subst_cls s c)
  | t -> t

and subst_cls s c =
  let ys' = List.map fresh c.tparams in
  let s' = adjoin_subst s (typ_subst c.tparams (List.map var ys')) in
  { c with
    tparams = ys';
    vparams = List.map (subst s') c.vparams;
    sup = subst s' c.sup;
    def = Subst.map (fun (sort, t) -> sort, subst s' t) c.def;
  }


(* Equivalence and Subtyping *)

let super_class c ts =
  subst (typ_subst c.tparams ts) c.sup

let eq_class c1 c2 = c1.name = c2.name

let rec eq t1 t2 =
  t1 == t2 ||
  match t1, t2 with
  | Var (y1, ts1), Var (y2, ts2) -> y1 = y2 && List.for_all2 eq ts1 ts2
  | Tup ts1, Tup ts2 ->
    List.length ts1 = List.length ts2 && List.for_all2 eq ts1 ts2
  | Array t1', Array t2' -> eq t1' t2'
  | Func (ys1, ts11, ts12), Func (ys2, ts21, ts22) ->
    List.length ys1 = List.length ys2 &&
    List.length ts11 = List.length ts21 &&
    List.length ts12 = List.length ts22 &&
    let ys' = List.map var (List.map fresh ys1) in
    let s1 = typ_subst ys1 ys' in
    let s2 = typ_subst ys2 ys' in
    List.for_all2 eq (List.map (subst s1) ts11) (List.map (subst s2) ts21) &&
    List.for_all2 eq (List.map (subst s1) ts12) (List.map (subst s2) ts22)
  | Inst (c1, ts1), Inst (c2, ts2) -> eq_class c1 c2 && List.for_all2 eq ts1 ts2
  | Class c1, Class c2 -> eq_class c1 c2
  | t1, t2 -> t1 = t2

let rec sub t1 t2 =
  t1 == t2 ||
  match t1, t2 with
  | Null, Obj -> true
  | Null, Array _ -> true
  | Null, Func _ -> true
  | Null, Inst _ -> true
  | Null, Class _ -> true
  | Inst _, Obj -> true
  | Tup ts1, Tup ts2 ->
    List.length ts1 = List.length ts2 && List.for_all2 sub ts1 ts2
  | Inst (c1, ts1), Inst (c2, ts2) ->
    eq_class c1 c2 && List.for_all2 eq ts1 ts2 || sub (super_class c1 ts1) t2
  | t1, t2 -> eq t1 t2

let rec lub t1 t2 =
  if sub t1 t2 then t2 else
  if sub t2 t1 then t1 else
  match t1, t2 with
  | Inst (c1, ts1), Inst (c2, ts2) ->
    lub (super_class c1 ts1) (super_class c2 ts2)
  | Tup ts1, Tup ts2 when List.length ts1 = List.length ts2 ->
    Tup (List.map2 lub ts1 ts2)
  | _, _ -> failwith "lub"


(* Classes *)

let class_cnts = ref Env.Map.empty

let class_name y =
  let i =
    match Env.Map.find_opt y !class_cnts with
    | None -> 0
    | Some i -> i
  in
  class_cnts := Env.Map.add y (i + 1) !class_cnts;
  if i = 0 then y else y ^ "/" ^ string_of_int i

let empty_class y ys =
  { name = y;
    tparams = ys;
    vparams = [];
    sup = Obj;
    def = Env.Map.empty;
  }

let gen_class y ys = empty_class (class_name y) ys