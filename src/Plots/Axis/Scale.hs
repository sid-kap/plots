{-# LANGUAGE DeriveFunctor         #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE TypeFamilies          #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Plots.Axis.Scale
-- Copyright   :  (C) 2015 Christopher Chalmers
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Christopher Chalmers
-- Stability   :  experimental
-- Portability :  non-portable
--
-- Determine how to scale an axis.
--
----------------------------------------------------------------------------

module Plots.Axis.Scale
  ( -- * Axis scale
    AxisScaling
  , ScaleMode (..)
  , UniformScaleStrategy (..)
  , Extending (..)
  , HasAxisScaling (..)

   -- ** Log scales
  , LogScale (..)
  , logNumber
  , logPoint
  , logDeform

    -- * Low level calculations
    -- | These functions are used by "Plots.Axis.Render".
  , calculateBounds
  , calculateScaling

  ) where

import           Control.Applicative
import           Control.Lens
import           Data.Bool
import           Data.Default
import           Data.Distributive
import           Data.Maybe

import           Diagrams
import           Linear

------------------------------------------------------------------------
-- Axis scale
------------------------------------------------------------------------

-- | How the axis should be scaled when not all dimensions are set.
data ScaleMode
  = AutoScale
  | NoScale
  | Stretch
  | UniformScale UniformScaleStrategy
  deriving (Show, Read)

-- | ?
data UniformScaleStrategy
  = AutoUniformScale
  | UnitOnly
  | ChangeVerticalLimits
  | ChangeHorizontalLimits
  deriving (Show, Read)

-- | Data type used that concerns everything to do with the size or
--   scale of the axis.
data AxisScaling n = Scaling
  { asRatio          :: Maybe n
  , asPostScale      :: Maybe n
  , asMode           :: ScaleMode
  , asEnlarge        :: Extending n
  , asOutputSize     :: Maybe n
  , asBoundMin       :: Maybe n
  , asBoundMax       :: Maybe n
  , asSize           :: Maybe n
  , asLogScale       :: LogScale

  -- backup bound in case there's no inferred bounds to go by
  , asBackupBoundMax :: n
  , asBackupBoundMin :: n
  }

type instance N (AxisScaling n) = n

instance Fractional n => Default (AxisScaling n) where
  def = Scaling
    { asRatio          = Nothing
    , asPostScale      = Nothing
    , asMode           = AutoScale
    , asEnlarge        = RelativeExtend 0.1
    , asOutputSize     = Just 300
    , asBoundMin       = Nothing
    , asBoundMax       = Nothing
    , asLogScale       = def
    , asBackupBoundMax = 5
    , asBackupBoundMin = -5
    , asSize           = Just 300
    }

-- | How much to extend the bounds beyond any inferred bounds.
data Extending n
  = AbsoluteExtend n
  | RelativeExtend n
  deriving (Show, Ord, Eq, Functor)

-- | Class of things that have an 'AxisScaling'.
class HasAxisScaling f a where
  -- | The way to scale in one direction.
  axisScaling :: LensLike' f a (AxisScaling (N a))

  -- | The ratio between this axis and other axes.
  scaleAspectRatio :: Functor f => LensLike' f a (Maybe (N a))
  scaleAspectRatio = axisScaling . lens asRatio (\as r -> as {asRatio = r})

  -- | How much to extend the bounds beyond any inferred bounds.
  scalePostScale :: Functor f => LensLike' f a (Maybe (N a))
  scalePostScale = axisScaling
                 . lens asPostScale (\as r -> as {asPostScale = r})

  -- | The ratio relative to other axis. If no ratios are set, the ratio
  --   is not enforced. If at least one is set, 'Nothing' ratios are
  --   @1@.
  scaleRatio :: Functor f => LensLike' f a (Maybe (N a))
  scaleRatio = axisScaling . lens asRatio (\as r -> as {asRatio = r})

  -- | The mode to determine how to scale the bounds in a direction.
  --   Choose between 'AutoScale', 'NoScale', 'Stretch' or
  --   'UniformScale'.
  --
  --   'Default' is 'AutoScale'.
  scaleMode :: Functor f => LensLike' f a ScaleMode
  scaleMode = axisScaling . lens asMode (\as r -> as {asMode = r})

  -- | Whether the axis uses 'LogAxis' or 'LinearAxis'.
  --
  --   'Default' is 'LinearAxis'.
  logScale :: Functor f => LensLike' f a LogScale
  logScale = axisScaling . lens asLogScale (\as r -> as {asLogScale = r})

  -- | How much to extend the bounds over infered bounds. This is
  --   ignored if a 'boundMax' or 'boundMin' is set.
  axisExtend :: Functor f => LensLike' f a (Extending (N a))
  axisExtend = axisScaling . lens asEnlarge (\as r -> as {asEnlarge = r})

  -- | The maximum bound the axis.
  boundMax :: Functor f => LensLike' f a (Maybe (N a))
  boundMax = axisScaling . lens asBoundMax (\as b -> as {asBoundMax = b})

  -- | The minimum bound the axis.
  boundMin :: Functor f => LensLike' f a (Maybe (N a))
  boundMin = axisScaling . lens asBoundMin (\as b -> as {asBoundMin = b})

  -- | The size of the rendered axis. Default is 500.
  renderSize :: Functor f => LensLike' f a (Maybe (N a))
  renderSize = axisScaling . lens asSize (\as s -> as {asSize = s})

  -- -- backup bound in case there's no inferred bounds to go by
  -- asBackupBoundMax :: n
  -- asBackupBoundMax :: n

asSizeSpec :: (HasLinearMap v, Num n, Ord n) => Lens' (v (AxisScaling n)) (SizeSpec v n)
asSizeSpec = column renderSize . iso mkSizeSpec getSpec

instance HasAxisScaling f (AxisScaling n) where
  axisScaling = id

-- calculating bounds --------------------------------------------------

-- | Calculating the bounds for an axis.
calculateBounds
  :: Num n
  => AxisScaling n -- ^ Scaling to use for this axis
  -> Maybe (n, n)  -- ^ Inferred bounds (from any plots)
  -> (n, n)        -- ^ Final bounds to use for this axis
calculateBounds Scaling {..} mInferred = (l', u') where
  -- bounds are only enlarged when min/max bound wasn't set
  l' = l & whenever (isNothing asBoundMin) (subtract x)
  u' = u & whenever (isNothing asBoundMax) (+ x)

  -- amount to enlarge axis by
  x = case asEnlarge of
    AbsoluteExtend a -> a
    RelativeExtend a -> (u - l) * a

  -- pre-enlarged bounds are looked at in the following order:
  --   - concrete bounds from max/boundMin
  --   - inferred bounds from plot envelopes
  --   - backup bounds
  l = fromMaybe asBackupBoundMin $ asBoundMin <|> lI
  u = fromMaybe asBackupBoundMax $ asBoundMax <|> uI
  lI = preview (folded . _1) mInferred
  uI = preview (folded . _2) mInferred

-- | Calculate the scaling for the axis.
--
--   The result returns:
--
--     - The final bounds for the axis
--     - scale to match desired 'scaleAspectRatio'
--     - scale to match desired 'asSizeSpec'
calculateScaling
  :: (HasLinearMap v, Distributive v, OrderedField n, Applicative v, Metric v)
  => v (AxisScaling n) -- ^ axis scaling options
  -> BoundingBox v n   -- ^ bounding box from the axis plots
  -> (v (n,n), Transformation v n, Transformation v n)
calculateScaling aScaling bb = (bounds, aspectScaling, sizeScaling) where

  -- final bounds of the axis
  bounds   = calculateBounds <$> aScaling <*> distribute inferred
  inferred = view _Point . uncurry (liftA2 (,)) <$> getCorners bb

  -- the scaling used to meet the desired aspect ratio
  aspectScaling
    -- if any of the aspect ratios are committed we use the aspect ratio from
    -- aScaling
    | anyOf (folded . scaleAspectRatio) isJust aScaling
        = vectorScaling (view (scaleAspectRatio . non 1) <$> aScaling)
    -- otherwise no ratios are set, ignore them and scale such
    -- that each axis is the same length
    | otherwise = inv $ vectorScaling v

  -- scaling used so the axis fits in the size spec
  sizeScaling = requiredScaling szSpec v'
  -- the vector that points from the lower bound to the upper bound of the
  -- axis
  v  = uncurry (flip (-)) <$> bounds
  v' = apply aspectScaling v
  szSpec = view asSizeSpec aScaling

-- | Scale transformation using the respective scale coefficients in the vector.
vectorScaling :: (Additive v, Fractional n) => v n -> Transformation v n
vectorScaling v = fromLinear f f
  where f = liftI2 (*) v <-> liftI2 (flip (/)) v

-- | Apply a function if the predicate is true.
whenever :: Bool -> (a -> a) -> a -> a
whenever b f = bool id f b

-- Logarithmic scaling -------------------------------------------------

-- Logarithmic scales are achieved by having 'LinearAxis' or 'LogAxis'
-- for each of the axes. When rendering the plots, they have axes the
-- log scheme. Some plots (like scatter) can easily do this whereas
-- others (like diagram plot) it's nearly impossible for, so they don't
-- bother.
--
-- Support for Log axis still needs a lot of work and debugging.

-- | Should the axis be on a logarithmic scale. The 'Default' is
--   'LinearAxis'.
data LogScale = LinearAxis | LogAxis
  deriving (Show, Eq)

instance Default LogScale where
  def = LinearAxis

-- | Log the number for 'LogAxis', do nothing for 'LinearAxis'.
logNumber :: Floating a => LogScale -> a -> a
logNumber LinearAxis = id
logNumber LogAxis    = log
{-# INLINE logNumber #-}

-- | Transform a point according to the axis scale. Does nothing for
--   linear scales.
logPoint :: (Additive v, Floating n) => v LogScale -> Point v n -> Point v n
logPoint v = _Point %~ liftI2 logNumber v
{-# INLINE logPoint #-}

-- | Deform an object according to the axis scale. Does nothing for
--   linear scales.
logDeform :: (InSpace v n a, Additive v, Foldable v, Floating n, Deformable a a)
          => v LogScale -> a -> a
logDeform v
  | allOf folded (== LinearAxis) v = id
  | otherwise                      = deform (Deformation $ logPoint v)

