module BrownPLT.JavaScript.ADsafe.SimplifyIf ( ifReduce ) where

import BrownPLT.JavaScript.Semantics.ANF
import BrownPLT.JavaScript.Semantics.Syntax

import Data.Generics

import qualified Data.Map as M
import qualified Data.Set as S

data RType = RNumber
           | RObject
           | RFunction -- a javascript function object
           | RLambda   -- a bona fide lambda expression
           | RString
           | RTrue
           | RFalse
           | RLocation
           | RNull
           | RUndefined
           | REval
             deriving (Show, Ord, Eq)
             
data AType = AString String --constant strings
           | AVar [RType]   --possible variable types for an ident/expr
           | ATypeOf Ident  --expression holding the type of an ident
           | ATypeIs Ident [RType]
           | ATypeIsNot Ident [RType]
             deriving (Show, Ord, Eq)

data T = A AType
       | R RType
         deriving (Show, Ord, Eq)

allT = [RNumber, RObject, RString, RFunction, 
        RTrue, RFalse, RLocation, RNull, RUndefined, RLambda]

type TEnv = M.Map Ident T

stringType :: String -> [RType]
stringType s =
    case s of
      "string" -> [RString]
      "number" -> [RNumber]
      "undefined" -> [RUndefined]
      "null" -> [RNull]
      "object" -> [RObject, RNull] -- typeof null === "object"
      "boolean" -> [RTrue, RFalse]
      "function" -> [RFunction]
      "lambda" -> [RLambda]
      "location" -> [RLocation]
      otherwise -> []
      -- don't check for eval here -- we don't check with typeof


isPrim :: RType -> Bool
isPrim RTrue = True
isPrim RFalse = True
isPrim RString = True
isPrim RNumber = True
isPrim RNull = True
isPrim RUndefined = True
isPrim _ = False


single :: RType -> T
single r = A (AVar [r])


bool = A (AVar [RTrue, RFalse])


union :: T -> T -> T
union (A (AVar r1)) (A (AVar r2)) = 
    A (AVar (S.toList (S.union (S.fromList r1) (S.fromList r2))))
union (A (AVar r1)) (R r) = A (AVar (r:r1))
union (R r) (A (AVar r1)) = A (AVar (r:r1))
union a b = (A (AVar allT))

remove :: [RType] -> T -> T
remove rs (A (AVar ts)) = 
    A (AVar (S.toList (S.difference (S.fromList ts) (S.fromList rs))))
remove r t = t

subType :: T -> T -> Bool
subType a b | (a==b) = True
subType (A (AVar [t])) (R r) = t==r
subType (A (AVar ts)) (A (AVar ts')) = (all (\t -> (S.member t (S.fromList ts'))) ts)
subType _ _ = False

-- returns the new value and the type for it
typeVal :: (Data a, Show a) => TEnv -> Value a -> (Value a, T)
typeVal env v =
    case v of
      VString a s -> (v, A (AString s))
      VId a x -> (v, case M.lookup x env of 
                       Just t -> t
                       Nothing -> A (AVar allT))
      VLambda a ids body ->
          let env' = 
                  (M.fromList 
                   (map (\x -> if x == "this"
                               then (x, single RLocation)
                               else (x, (A (AVar allT)))) ids)) in
          (VLambda a ids (fst (typeExp (M.union env' env) body)), 
           single RFunction)
      VNumber a n -> (v, single RNumber)
      VBool a True -> (v, single RTrue)
      VBool a False -> (v, single RFalse)
      VUndefined a -> (v, single RUndefined)
      VNull a -> (v, single RNull)
      VEval a -> (v, single REval)


typeBind :: (Data a, Show a) => TEnv -> BindExp a -> (BindExp a, T)
typeBind env b =
    case b of
      BObject a fields -> 
          let newfields = (zip (map fst fields)
                           (map fst 
                            (map (typeVal env) 
                             (map snd fields)))) in
          (BObject a newfields, single RObject)
      BSetRef a id v2 ->
          let (v2', t2) = typeVal env v2 in
          (BSetRef a id v2', t2)
      BRef a v ->
          let (v', t) = typeVal env v in
          (BRef a v', single RLocation)
      BDeref a (VId a2 "$global") ->
          (BDeref a (VId a2 "$global"), single RObject)
      BDeref a v ->
          let (v', t) = typeVal env v in
          (BDeref a v', A (AVar allT))  -- we know nothing about refs
      BGetField a v1 v2 ->
          let (v1', t1) = typeVal env v1
              (v2', t2) = typeVal env v2 in
          (BGetField a v1' v2', A (AVar allT)) -- we know nothing about objects
      BUpdateField a v1 v2 v3 ->
          let (v1', t1) = typeVal env v1
              (v2', t2) = typeVal env v2
              (v3', t3) = typeVal env v3 in
          (BUpdateField a v1' v2' v3', single RObject)
      BDeleteField a v1 v2 ->
          let (v1', t1) = typeVal env v1
              (v2', t2) = typeVal env v2 in
          (BDeleteField a v1' v2', single RUndefined)
      BValue a v ->
          let (v', t) = typeVal env v in
          (BValue a v', t)
      BApp a f xs ->
          let xs' = map fst (map (typeVal env) xs)
              (f', t) = typeVal env f in
          (BApp a f' xs', A (AVar allT))
      BIf a c (AReturn a1 (VBool a2 False)) (AReturn a3 (VBool a4 True)) ->
          let (c', tc) = typeVal env c
              rettype = case tc of
                          A (AVar [RTrue]) -> single RFalse
                          A (AVar [RFalse]) -> single RTrue
                          A (ATypeIs x ts) -> A (ATypeIsNot x ts)
                          A (ATypeIsNot x ts) -> A (ATypeIs x ts)
                          otherwise -> bool in
          (BIf a c' (AReturn a1 (VBool a2 False)) (AReturn a3 (VBool a4 True)), rettype)
      BIf a c thn els ->
          let (c', tc) = typeVal env c in
          case tc of 
            A (AVar [RTrue]) ->
                let (thn', t_thn) = typeExp env thn in
                (BIf a c' thn' (AReturn a (VString a "$unreachable")), t_thn)
            A (AVar [RFalse]) ->
                let (els', t_els) = typeExp env els in
                ((BIf a c' (AReturn a (VString a "$unreachable")) els'), t_els)
            A (ATypeIs x ts) -> 
                let tx = snd (typeVal env (VId a x)) in
                case tx of
                  A (AVar ts') ->
                      if all (\t -> (S.member t) (S.fromList ts')) ts then
                          let (thn', t_thn) = typeExp (M.insert x (A (AVar ts)) env) thn
                              (els', t_els) = typeExp (M.insert x (remove ts tx) env) els in
                          (BIf a c' thn' els', union t_thn t_els)
                      else
                          let (els', t_els) = typeExp env els
                              (thn', t_thn) = typeExp env thn in
                          (BIf a c' thn' els', union t_thn t_els)
                  otherwise -> defaultIf env b
            A (ATypeIsNot x ts) -> 
                let tx = snd (typeVal env (VId a x)) in
                case tx of
                  A (AVar ts') ->
                      if all (\t -> (S.member t) (S.fromList ts')) ts then
                          let (thn', t_thn) = typeExp (M.insert x (remove ts tx) env) thn
                              (els', t_els) = typeExp (M.insert x (A (AVar ts)) env) els in
                          (BIf a c' thn' els', union t_thn t_els)
                      else
                          let (thn', t_thn) = typeExp env thn 
                              (els', t_els) = typeExp env els in
                          (BIf a c' thn' els', union t_thn t_els)
                  otherwise -> defaultIf env b
            otherwise -> defaultIf env b
      BOp a op xs -> bop env b

typeTest :: (Data a, Show a) => TEnv -> Value a -> [RType] -> T
typeTest env x ts =
    case typeVal env x of
      (_, A (AVar rs)) | all (\r -> S.member r (S.fromList ts)) rs -> A (AVar [RTrue])
      (_, A (AVar rs)) | all (\r -> S.notMember r (S.fromList ts)) rs -> A (AVar [RFalse])
      (VId a ident, _) -> A (ATypeIs ident ts)
      otherwise -> bool -- shouldn't happen

bop :: (Data a, Show a) => TEnv -> BindExp a -> (BindExp a, T)
bop env b =
    case b of
      BOp a OStrictEq [VId _ x, VNull _] ->
          (b, typeTest env (VId a x) [RNull])
      BOp a OStrictEq [VId _ x, VUndefined _] ->
          (b, typeTest env (VId a x) [RUndefined])
      BOp a OStrictEq [x, y] ->
          let (x', tx) = typeVal env x
              (y', ty) = typeVal env y in
          case (tx, ty) of
            (A (ATypeOf ident), A (AString s)) -> 
                (BOp a OStrictEq [x', y'], typeTest env (VId a ident) (stringType s))--A (ATypeIs ident (stringType s)))
            (A (AString s), A (ATypeOf ident)) -> 
                (BOp a OStrictEq [x', y'], typeTest env (VId a ident) (stringType s))--A (ATypeIs ident (stringType s)))
            otherwise -> 
                (BOp a OStrictEq [x', y'], bool)
      BOp a1 OTypeof [(VId a2 x)] ->
          let (x', tx) = typeVal env (VId a2 x) in
          (BOp a1 OTypeof [x'], A (ATypeOf x))
      BOp a1 OSurfaceTypeof [(VId a2 x)] ->
          let (x', tx) = typeVal env (VId a2 x) in
          (BOp a1 OSurfaceTypeof [x'], A (ATypeOf x))
      BOp a OPrimToBool [x] -> 
          let (x', tx) = typeVal env x
              def = (BOp a OPrimToBool [x']) in
          case tx of
            A (AVar [RTrue]) -> (BValue a x', tx)
            A (AVar [RFalse]) -> (BValue a x', tx)
            A (AVar [RString]) -> (def, A (AVar [RTrue])) -- prim->bool for strings is true
            A (AVar [RUndefined]) -> (def, A (AVar [RFalse])) -- prim->bool for undefined is false
            A (AVar [RTrue, RFalse]) -> (BValue a x', bool)
            A (ATypeIs y rs) -> (BValue a x', A (ATypeIs y rs))
            A (ATypeIsNot y rs) -> (BValue a x', A (ATypeIsNot y rs))
            otherwise -> (def, bool)
      BOp a OPrimToStr [x] ->
          let (x', tx) = typeVal env x in
          case tx of
            A (AVar [RString]) -> (BValue a x', single RString)
            otherwise -> (BOp a OPrimToStr [x], single RString)
      BOp a OIsPrim [x] ->
          let (x', tx) = typeVal env x in
          case tx of
            A (AVar ts) | all isPrim ts -> (BValue a (VBool a True), single RTrue)
            A (AVar ts) | not (any isPrim ts) -> (BValue a (VBool a False), single RFalse)
            otherwise -> (BOp a OIsPrim [x'], bool)
      BOp a op xs ->
          let xs' = map fst (map (typeVal env) xs)
              ts = map snd (map (typeVal env) xs) in
          (BOp a op xs', A (AVar (opType op)))
      otherwise -> (BValue (label b) (VString (label b) "bop not given BOp"), single RUndefined)


opType :: Op -> [RType]
opType op = 
    case op of
      ONumPlus -> [RNumber]
      OMul -> [RNumber]
      ODiv -> [RNumber]
      OMod -> [RNumber]
      OSub -> [RNumber]
      OBAnd -> [RNumber]
      OBOr -> [RNumber]
      OBXOr -> [RNumber]
      OBNot -> [RNumber]
      OLShift -> [RNumber]
      OSpRShift -> [RNumber]
      OZfRShift -> [RNumber]
      OPrimToNum -> [RNumber]
      OToInteger -> [RNumber]
      OToInt32 -> [RNumber]
      OToUInt32 -> [RNumber]
      OMathExp -> [RNumber]
      OMathLog -> [RNumber]
      OMathCos -> [RNumber]
      OMathSin -> [RNumber]
      OMathAbs -> [RNumber]
      OMathPow -> [RNumber]
      OStrLen -> [RNumber]

      OPrint -> [RUndefined]

      OLt -> [RTrue, RFalse]
      OStrictEq -> [RTrue, RFalse]
      OAbstractEq -> [RTrue, RFalse]
      OPrimToBool -> [RTrue, RFalse]
      OIsPrim -> [RTrue, RFalse]
      OHasOwnProp -> [RTrue, RFalse]
      OStrContains -> [RTrue, RFalse]
      OStrStartsWith -> [RTrue, RFalse]
      OObjIterHasNext -> [RTrue, RFalse]
      OObjCanDelete -> [RTrue, RFalse]

      -- Arrays
      OStrSplitRegExp -> [RObject]
      OStrSplitStrExp -> [RObject]
      ORegExpMatch -> [RObject,RNull,RUndefined]
      ORegExpQuote -> [RObject]

      OStrPlus -> [RString]
      OStrLt -> [RString]
      OTypeof -> [RString]
      OSurfaceTypeof -> [RString]
      OPrimToStr -> [RString]
      -- Keys of objects are strings
      OObjIterNext -> [RString]
      OObjIterKey -> [RString]

defaultIf :: (Data a, Show a) => TEnv -> BindExp a -> (BindExp a, T)
defaultIf env b = 
    case b of
      BIf a c t e ->
          let (c', tc) = typeVal env c
              (t', tt) = typeExp env t
              (e', te) = typeExp env e in
          (BIf a c' t' e', union tt te)
      otherwise -> ((BValue (label b) (VString (label b) "defaultIf not passed an if expression")), single RUndefined) -- this should never happen

typeExp :: (Data a, Show a) => TEnv -> Exp a -> (Exp a, T)
typeExp env e = 
    case e of 
      {-
        Dead code elimination for:

        (let [(x (if c "$unreachable" e))] x) => e

       -}
      ALet a1 [(x, BIf a2 c thn els)] (AReturn a3 (VId a4 y)) | x==y ->
           let (if', tif) = typeBind env (BIf a2 c thn els) in
           case if' of
             BIf a' c (AReturn _ (VString _ "$unreachable")) els ->
                 typeExp env els
             BIf a' c thn (AReturn _ (VString _ "$unreachable")) ->
                 typeExp env thn
             otherwise ->
                 (ABind a1 if', tif)
      {-
        If you have something like

        (let [(x (if c "$unreachable" v))] body)
        
        this is equivalent to 
        
        (let [(x v)] body), as long as v is a value or bind exp

       -}
      ALet a1 [(x, BIf a2 c thn els)] body ->
          let (if', tif) = typeBind env (BIf a2 c thn els) in
          case if' of
            BIf a' c (AReturn _ (VString _ "$unreachable")) (AReturn a2 v) ->
                 let (v', tv) = typeVal env v
                     (body', tbody) = typeExp (M.insert x tv env) body in
                 (ALet a1 [(x, (BValue a2 v'))] body', tbody)
            BIf a' c (AReturn a2 v) (AReturn _ (VString _ "$unreachable")) ->
                 let (v', tv) = typeVal env v
                     (body', tbody) = typeExp (M.insert x tv env) body in
                 (ALet a1 [(x, (BValue a2 v'))] body', tbody)
            BIf a' c (AReturn _ (VString _ "$unreachable")) (ABind a2 b) ->
                 let (b', tb) = typeBind env b
                     (body', tbody) = typeExp (M.insert x tb env) body in
                 (ALet a1 [(x, b')] body', tbody)
            BIf a' c (ABind a2 b) (AReturn _ (VString _ "$unreachable")) ->
                 let (b', tb) = typeBind env b
                     (body', tbody) = typeExp (M.insert x tb env) body in
                 (ALet a1 [(x, b')] body', tbody)
            otherwise -> 
                let (body', tbody) = typeExp (M.insert x tif env) body in
                (ALet a1 [(x, if')] body', tbody)
      {-
        Performs the follwing simplification:
        
        (let ([x e]) x) => e
        
       -}
      ALet a1 [(x, b)] (AReturn a2 (VId a3 y)) | x==y ->
           let (b', tb) = typeBind env b in
           (ABind a1 b', tb)
      ALet a1 [(x1, BDeref a2 (VId a7 "$global"))]
           (ALet a3 [(x2, BGetField a4 (VId a5 x1') (VString a6 "document"))] 
                body) | x1 == x1' ->
          let (body', tbody) = typeExp (M.insert x2 (single RObject) env) body in
          (ALet a1 [(x1, BDeref a2 (VId a7 "$global"))]
                (ALet a3 [(x2, BGetField a4 (VId a5 x1') (VString a6 "document"))] 
                     body'), tbody)
      ALet a binds body ->
          let pairs = map (typeBind env) (map snd binds)
              (xs, ts) = (map fst pairs, map snd pairs)
              binds' = zip (map fst binds) (xs)
              env' = foldl (\acc_env pair -> 
                                 M.insert (fst pair) (snd pair) acc_env)
                      env (zip (map fst binds) ts)
              (body', tbody) = typeExp env' body in
          (ALet a binds' body', tbody)
      ASeq a e1 e2 ->
          let (e1', e1type) = typeExp env e1
              (e2', e2type) = typeExp env e2 in
          (ASeq a e1' e2', e2type)
      ALabel a lbl body ->
          let (body', tbody) = typeExp env body in
          (ALabel a lbl body', tbody)
      ACatch a body catch ->
          let (body', tbody) = typeExp env body
              (catch', tcatch) = typeVal env catch in
          (ACatch a body' catch', A (AVar allT))
      ABreak a lbl v ->
          let (v', tv) = typeVal env v in
          (ABreak a lbl v', tv)
      AThrow a v ->
          let (v', tv) = typeVal env v in
          (AThrow a v', tv)
      AFinally a body final ->
          let (body', tbody) = typeExp env body
              (final', tfinal) = typeExp env final in
          (AFinally a body' final', union tbody tfinal)
      AReturn a v ->
          let (v', tv) = typeVal env v in
          (AReturn a v', tv)
      ABind a b ->
          let (b', tb) = typeBind env b in
          (ABind a b', tb)
                                 
globalEnv =
  [ "$global", "$Object.prototype", "$Function.prototype", "$Date.prototype"
  , "$Number.prototype", "$Array.prototype", "$Boolean.prototype"
  , "$Error.prototype", "$Boolean.prototype", "$Error.prototype" 
  , "$ConversionError.prototype", "$RangeError.prototype" 
  , "$ReferenceError.prototype", "$SyntaxError.prototype" 
  , "$TypeError.prototype", "$URIError.prototype", "Object", "Function"
  , "Array", "$RegExp.prototype", "RegExp", "Date", "Number"
  , "$String.prototype", "String", "Boolean", "Error", "ConversionError"
  , "EvalError", "RangeError", "ReferenceError", "SyntaxError", "TypeError"
  , "URIError", "this", "$makeException"
  ]
          
ifReduce :: (Data a, Show a) => Exp a -> Exp a                       
ifReduce e = fst (typeExp (M.fromList (map (\x -> (x, single RLocation)) globalEnv))  e)