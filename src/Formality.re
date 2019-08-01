include Formality__Validation.Result;
include Formality__Validation.Sync;
include Formality__PublicHelpers;

module Strategy = Formality__Strategy;
module FormStatus = Formality__FormStatus;

module Make = Formality__Form.MakeWithDefaultId;
module MakeId = Formality__Form.Make;

module Async = {
  include Formality__Validation.Async;
  module Make = Formality__FormAsyncOnChange.MakeWithDefaultId;
  module MakeId = Formality__FormAsyncOnChange.Make;

  module MakeOnBlur = Formality__FormAsyncOnBlur.MakeWithDefaultId;
  module MakeOnBlurId = Formality__FormAsyncOnBlur.Make;
  let debounceInterval = Formality__FormAsyncOnChange.defaultDebounceInterval;
};
