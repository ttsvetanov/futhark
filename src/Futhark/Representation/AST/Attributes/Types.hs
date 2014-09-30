module Futhark.Representation.AST.Attributes.Types
       (
         arrayRank
       , arrayShape
       , uniqueness
       , setUniqueness
       , unifyUniqueness
       , unique
       , staticShapes
       , hasStaticShape
       , instantiateShapes
       , instantiatePattern
       , basicType
       , basicDecl
       , toDecl

       , arrayOf
       , setOuterSize
       , setArrayShape
       , setArrayDims
       , peelArray
       , stripArray
       , arrayDims
       , arraySize
       , arraysSize
       , rowType
       , elemType

       , diet
       , dietingAs

       , subuniqueOf
       , subtypeOf
       , subtypesOf
       , similarTo

       , generaliseResTypes
       , existentialShapes
       , shapeContext
       , contextSize
       )
       where

import Control.Applicative
import Control.Monad.State
import Data.Loc
import Data.Maybe
import Data.Monoid
import qualified Data.HashMap.Lazy as HM
import qualified Data.HashSet as HS

import Futhark.Representation.AST.Syntax
import Futhark.Representation.AST.Attributes.Constants

-- | Given a basic type, construct a type without aliasing and shape
-- information.  This is sometimes handy for disambiguation when
-- constructing types.
basicDecl :: BasicType -> DeclType
basicDecl = Basic

-- | Remove aliasing and shape information from a type.
toDecl :: ArrayShape shape => TypeBase shape -> DeclType
toDecl (Array et sz u) = Array et (Rank $ shapeRank sz) u
toDecl (Basic et) = Basic et

-- | Return the dimensionality of a type.  For non-arrays, this is
-- zero.  For a one-dimensional array it is one, for a two-dimensional
-- it is two, and so forth.
arrayRank :: ArrayShape shape => TypeBase shape -> Int
arrayRank = shapeRank . arrayShape

-- | Return the shape of a type - for non-arrays, this is the
-- 'mempty'.
arrayShape :: ArrayShape shape => TypeBase shape -> shape
arrayShape (Array _ ds _) = ds
arrayShape _              = mempty

-- | Return the uniqueness of a type.
uniqueness :: TypeBase shape -> Uniqueness
uniqueness (Array _ _ u) = u
uniqueness _ = Nonunique

-- | @unique t@ is 'True' if the type of the argument is unique.
unique :: TypeBase shape -> Bool
unique = (==Unique) . uniqueness

-- | Set the uniqueness attribute of a type.  If the type is a tuple,
-- the uniqueness of its components will be modified.
setUniqueness :: TypeBase shape -> Uniqueness -> TypeBase shape
setUniqueness (Array et dims _) u = Array et dims u
setUniqueness t _ = t

-- | Unify the uniqueness attributes and aliasing information of two
-- types.  The two types must otherwise be identical.  The resulting
-- alias set will be the 'mappend' of the two input types aliasing sets,
-- and the uniqueness will be 'Unique' only if both of the input types
-- are unique.
unifyUniqueness :: TypeBase shape -> TypeBase shape -> TypeBase shape
unifyUniqueness (Array et dims u1) (Array _ _ u2) =
  Array et dims (u1 <> u2)
unifyUniqueness t1 _ = t1

-- | Convert types with non-existential shapes to types with
-- non-existential shapes.  Only the representation is changed, so all
-- the shapes will be 'Free'.
staticShapes :: [TypeBase Shape] -> [TypeBase ExtShape]
staticShapes = map staticShapes'
  where staticShapes' (Basic bt) =
          Basic bt
        staticShapes' (Array bt (Shape shape) u) =
          Array bt (ExtShape $ map Free shape) u

hasStaticShape :: ResType -> Maybe [Type]
hasStaticShape = mapM hasStaticShape'
  where hasStaticShape' (Basic bt) =
          Just $ Basic bt
        hasStaticShape' (Array bt (ExtShape shape) u) =
          Array bt <$> (Shape <$> mapM isFree shape) <*> pure u
        isFree (Free s) = Just s
        isFree (Ext _)  = Nothing

instantiateShapes :: Monad m => m SubExp -> [TypeBase ExtShape]
                  -> m [TypeBase Shape]
instantiateShapes f ts = evalStateT (mapM instantiate ts) HM.empty
  where instantiate t = do
          shape <- mapM instantiate' $ extShapeDims $ arrayShape t
          return $ t `setArrayShape` Shape shape
        instantiate' (Ext x) = do
          m <- get
          case HM.lookup x m of
            Just se -> return se
            Nothing -> do se <- lift f
                          put $ HM.insert x se m
                          return se
        instantiate' (Free se) = return se

instantiatePattern :: SrcLoc -> [VName] -> ResType -> Maybe ([Ident], [Ident])
instantiatePattern loc names ts
  | let n = contextSize ts,
    n + length ts == length names = do
    let (context, vals) = splitAt n names
        mkIdent name t = Ident name t loc
        nextShape = do
          (context', remaining) <- get
          case remaining of []   -> lift Nothing
                            x:xs -> do let ident = Ident x (Basic Int) loc
                                       put (context'++[ident], xs)
                                       return $ Var ident
    (ts', (context', _)) <-
      runStateT (instantiateShapes nextShape ts) ([],context)
    return (context', zipWith mkIdent vals ts')
  | otherwise = Nothing

-- | @arrayOf t s u@ constructs an array type.  The convenience
-- compared to using the 'Array' constructor directly is that @t@ can
-- itself be an array.  If @t@ is an @n@-dimensional array, and @s@ is
-- a list of length @n@, the resulting type is of an @n+m@ dimensions.
-- The uniqueness of the new array will be @u@, no matter the
-- uniqueness of @t@.
arrayOf :: (ArrayShape shape) =>
           TypeBase shape -> shape -> Uniqueness -> TypeBase shape
arrayOf (Array et size1 _) size2 u =
  Array et (size2 <> size1) u
arrayOf (Basic et) size u =
  Array et size u

-- | Set the shape of an array.  If the given type is not an
-- array, return the type unchanged.
setArrayShape :: ArrayShape newshape =>
                 TypeBase oldshape -> newshape -> TypeBase newshape
setArrayShape (Array et _ u) ds
  | shapeRank ds == 0 = Basic et
  | otherwise         = Array et ds u
setArrayShape (Basic t)  _         = Basic t

-- | Set the dimensions of an array.  If the given type is not an
-- array, return the type unchanged.
setArrayDims :: TypeBase oldshape -> [SubExp] -> TypeBase Shape
setArrayDims t dims = t `setArrayShape` Shape dims

-- | Replace the size of the outermost dimension of an array.  If the
-- given type is not an array, it is returned unchanged.
setOuterSize :: TypeBase Shape -> SubExp -> TypeBase Shape
setOuterSize t e = case arrayShape t of
                      Shape (_:es) -> t `setArrayShape` Shape (e : es)
                      _            -> t

-- | @peelArray n t@ returns the type resulting from peeling the first
-- @n@ array dimensions from @t@.  Returns @Nothing@ if @t@ has less
-- than @n@ dimensions.
peelArray :: ArrayShape shape =>
             Int -> TypeBase shape -> Maybe (TypeBase shape)
peelArray 0 t = Just t
peelArray n (Array et shape u)
  | shapeRank shape == n = Just $ Basic et
  | shapeRank shape >  n = Just $ Array et (stripDims n shape) u
peelArray _ _ = Nothing

-- | @stripArray n t@ removes the @n@ outermost layers of the array.
-- Essentially, it is the type of indexing an array of type @t@ with
-- @n@ indexes.
stripArray :: ArrayShape shape => Int -> TypeBase shape -> TypeBase shape
stripArray n (Array et shape u)
  | n < shapeRank shape = Array et (stripDims n shape) u
  | otherwise           = Basic et
stripArray _ t = t

-- | Return the dimensions of a type - for non-arrays, this is the
-- empty list.
arrayDims :: TypeBase Shape -> [SubExp]
arrayDims = shapeDims . arrayShape

-- | Return the size of the given dimension.  If the dimension does
-- not exist, the zero constant is returned.
arraySize :: Int -> TypeBase Shape -> SubExp
arraySize i t = case drop i $ arrayDims t of
                  e : _ -> e
                  _     -> intconst 0 noLoc

-- | Return the size of the given dimension in the first element of
-- the given type list.  If the dimension does not exist, or no types
-- are given, the zero constant is returned.
arraysSize :: Int -> [TypeBase Shape] -> SubExp
arraysSize _ []    = intconst 0 noLoc
arraysSize i (t:_) = arraySize i t

-- | Return the immediate row-type of an array.  For @[[int]]@, this
-- would be @[int]@.
rowType :: ArrayShape shape => TypeBase shape -> TypeBase shape
rowType = stripArray 1

-- | A type is a basic type if it is not an array and any component
-- types are basic types.
basicType :: TypeBase shape -> Bool
basicType (Array {}) = False
basicType _ = True

-- | Returns the bottommost type of an array.  For @[[int]]@, this
-- would be @int@.  If the given type is not an array, it is returned.
elemType :: TypeBase shape -> BasicType
elemType (Array t _ _) = t
elemType (Basic t)     = t

-- | @diet t@ returns a description of how a function parameter of
-- type @t@ might consume its argument.
diet :: TypeBase shape -> Diet
diet (Basic _) = Observe
diet (Array _ _ Unique) = Consume
diet (Array _ _ Nonunique) = Observe

-- | @t `dietingAs` d@ modifies the uniqueness attributes of @t@ to
-- reflect how it is consumed according to @d@ - if it is consumed, it
-- becomes 'Unique'.  Tuples are handled intelligently.
dietingAs :: TypeBase shape -> Diet -> TypeBase shape
t `dietingAs` Consume =
  t `setUniqueness` Unique
t `dietingAs` _ =
  t `setUniqueness` Nonunique

-- | @x `subuniqueOf` y@ is true if @x@ is not less unique than @y@.
subuniqueOf :: Uniqueness -> Uniqueness -> Bool
subuniqueOf Nonunique Unique = False
subuniqueOf _ _ = True

-- | @x \`subtypeOf\` y@ is true if @x@ is a subtype of @y@ (or equal to
-- @y@), meaning @x@ is valid whenever @y@ is.
subtypeOf :: ArrayShape shape => TypeBase shape -> TypeBase shape -> Bool
subtypeOf (Array t1 shape1 u1) (Array t2 shape2 u2) =
  u1 `subuniqueOf` u2
       && t1 == t2
       && shapeRank shape1 == shapeRank shape2
subtypeOf (Basic t1) (Basic t2) = t1 == t2
subtypeOf _ _ = False

-- | @xs \`subtypesOf\` ys@ is true if @xs@ is the same size as @ys@,
-- and each element in @xs@ is a subtype of the corresponding element
-- in @ys@..
subtypesOf :: ArrayShape shape => [TypeBase shape] -> [TypeBase shape] -> Bool
subtypesOf xs ys = length xs == length ys &&
                   and (zipWith subtypeOf xs ys)

-- | @x \`similarTo\` y@ is true if @x@ and @y@ are the same type,
-- ignoring uniqueness.
similarTo :: ArrayShape shape => TypeBase shape -> TypeBase shape -> Bool
similarTo t1 t2 = t1 `subtypeOf` t2 || t2 `subtypeOf` t1

-- | Compute the most specific generalisation of two types with
-- existentially quantified shapes.
generaliseResTypes :: ResType -> ResType -> ResType
generaliseResTypes rt1 rt2 =
  evalState (zipWithM unifyExtShapes rt1 rt2) (0, HM.empty)
  where unifyExtShapes t1 t2 =
          unifyUniqueness <$>
          (setArrayShape t1 <$> ExtShape <$>
           zipWithM unifyExtDims
           (extShapeDims $ arrayShape t1)
           (extShapeDims $ arrayShape t2)) <*>
          pure t2
        unifyExtDims (Free se1) (Free se2)
          | se1 == se2 = return $ Free se1 -- Arbitrary
          | otherwise  = do (n,m) <- get
                            put (n + 1, m)
                            return $ Ext n
        unifyExtDims (Ext x) (Ext y)
          | x == y = Ext <$> (maybe (new x) return =<<
                              gets (HM.lookup x . snd))
        unifyExtDims (Ext x) _ = Ext <$> new x
        unifyExtDims _ (Ext x) = Ext <$> new x
        new x = do (n,m) <- get
                   put (n + 1, HM.insert x n m)
                   return n

existentialShapes :: [TypeBase ExtShape] -> [TypeBase Shape]
                  -> [SubExp]
existentialShapes t1s t2s = concat $ zipWith concreteShape' t1s t2s
  where concreteShape' t1 t2 =
          catMaybes $ zipWith concretise
          (extShapeDims $ arrayShape t1)
          (shapeDims $ arrayShape t2)
        concretise (Ext _) se  = Just se
        concretise (Free _) _  = Nothing

shapeContext :: ResType -> [[a]] -> [a]
shapeContext ts shapes =
  evalState (concat <$> zipWithM extract ts shapes) HS.empty
  where extract t shape =
          catMaybes <$> zipWithM extract' (extShapeDims $ arrayShape t) shape
        extract' (Ext x) v = do
          seen <- gets $ HS.member x
          if seen then return Nothing
            else do modify $ HS.insert x
                    return $ Just v
        extract' (Free _) _ = return Nothing

-- | Return the number of distinct variables in the existential context.
contextSize :: ResType -> Int
contextSize = HS.size
              . HS.fromList
              . concatMap (mapMaybe existential . extShapeDims . arrayShape)
  where existential (Ext x)  = Just x
        existential (Free _) = Nothing