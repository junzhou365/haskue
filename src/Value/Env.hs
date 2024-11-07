{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}

module Value.Env where

import Control.Monad.Except (MonadError)
import Control.Monad.Logger (MonadLogger)

type Env m = (MonadError String m, MonadLogger m)
