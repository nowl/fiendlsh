(in-package :fiendish-rl)

(defparameter *epsilon* 1e-6)

(defparameter *ticks-per-second* 60)
(defparameter *ms-per-tick* (/ 1000 *ticks-per-second*))
(defparameter *next-tick-ms* 0)
(defparameter *max-frame-skip* 5)

(defparameter *draw-count* 0)
(defparameter *startup-time-ms* 0)

(defparameter *running* t)

(defparameter *keyboard-state* (make-hash-table))

(defparameter *keyboard-initial-delay-ms* 60)
(defparameter *keyboard-repeat-delay-ms* 60)

(defparameter *fire-sound* nil)
(defparameter *destroy-sound* nil)
(defparameter *score* 0)
(defparameter *max-score* 0)

(defstruct key-state
  mod
  pressed
  in-repeat
  time-pressed)

(defun move-player (dir)
  (ecase dir
    (:up (setf (player-ship-accel-y *player-ship*) (- (player-ship-thrust *player-ship*))
               (player-ship-dir *player-ship*) :ship-up))
    (:down (setf (player-ship-accel-y *player-ship*) (player-ship-thrust *player-ship*)
                 (player-ship-dir *player-ship*) :ship-down))
    (:left (setf (player-ship-accel-x *player-ship*) (- (player-ship-thrust *player-ship*))
                 (player-ship-dir *player-ship*) :ship-left))
    (:right (setf (player-ship-accel-x *player-ship*) (player-ship-thrust *player-ship*)
                  (player-ship-dir *player-ship*) :ship-right))))

(defun update-enemy-ships ()
  (let (delete-list)
    (loop for s in *enemy-ships* do
         (funcall (enemy-ship-behavior s) s)
         (incf (enemy-ship-x s) (enemy-ship-dx s))
         (incf (enemy-ship-y s) (enemy-ship-dy s))
  
         (when (> (manhattan-dist-to-player (enemy-ship-x s) (enemy-ship-y s))
                  (* 2 *screen-width*))
           (push s delete-list)))
    (loop for d in delete-list do
         (setf *enemy-ships* (delete d *enemy-ships* :test #'eq)))))

(defun get-held-keys ()
  (let (results)
    (loop with tick = (fiendish-rl.ffi:getticks)
       for key being the hash-key of *keyboard-state* using (hash-value key-state) do
         (when (key-state-pressed key-state)
           (cond
             ((and (key-state-in-repeat key-state) 
                   (>= (- tick (key-state-time-pressed key-state)) *keyboard-repeat-delay-ms*))
              (push (list key (key-state-mod key-state)) results)
              (setf (key-state-time-pressed key-state) tick))
             ((and (not (key-state-in-repeat key-state))
                   (>= (- tick (key-state-time-pressed key-state)) *keyboard-initial-delay-ms*))
              (push (list key (key-state-mod key-state)) results)
              (setf (key-state-time-pressed key-state) tick
                    (key-state-in-repeat key-state) t)))))
    results))

(defun keyboard-update (type value mod)
  (let ((kstate (gethash value *keyboard-state*)))
    (ecase type
      (:press (cond
                ((and kstate (key-state-pressed kstate)) (return-from keyboard-update nil))
                (kstate (setf (key-state-pressed kstate) t
                              (key-state-time-pressed kstate) (fiendish-rl.ffi:getticks)
                              (key-state-in-repeat kstate) nil))
                (t (setf (gethash value *keyboard-state*) (make-key-state :mod mod
                                                                          :pressed t
                                                                          :in-repeat nil
                                                                          :time-pressed (fiendish-rl.ffi:getticks)))))
              (handle-keypress value mod))
      (:release (setf (key-state-pressed kstate) nil)))))

(defun maybe-make-debris (tick)
  (when (and (> tick *next-debris-check*) (< (length *debris*) 50))
    (incf *next-debris-check* *debris-check-ms*)
    (let ((ix (player-ship-x *player-ship*))
          (iy (player-ship-y *player-ship*))
          (r *screen-width*)
          (angle (random (* 2 pi))))
    (push (make-debris :x (+ ix (* r (cos angle)))
                       :y (+ iy (* r (sin angle)))
                       :dx (- (random 2.0) 1)
                       :dy (- (random 2.0) 1))
          *debris*))))

(defun maybe-make-enemy-ship (tick)
  (when (> tick *next-enemy-ship-check*)
    (incf *next-enemy-ship-check* *enemy-ship-check-ms*)
    (let ((ix (player-ship-x *player-ship*))
          (iy (player-ship-y *player-ship*))
          (r *screen-width*)
          (angle (random (* 2 pi))))
    (push (make-enemy-ship :x (+ ix (* r (cos angle)))
                           :y (+ iy (* r (sin angle)))
                           :dx 0
                           :dy 0
                           :accx 0
                           :accy 0
                           :lifetime (fiendish-rl.ffi:getticks)
                           :type (random 2)
                           :behavior (ecase (random 3)
                                       (0 #'ship-move-towards-player)
                                       (1 #'cutoff-player-x)
                                       (2 #'cutoff-player-y)))
          *enemy-ships*))))

(defun maybe-make-coin (tick)
  (when (> tick *next-coin-check*)
    (incf *next-coin-check* *coin-check-ms*)
    (let ((ix (player-ship-x *player-ship*))
          (iy (player-ship-y *player-ship*))
          (r *screen-width*)
          (angle (random (* 2 pi))))
      (push (make-coin :x (+ ix (* r (cos angle)))
                       :y (+ iy (* r (sin angle)))
                       :state :coin1
                       :to-flip 30)
            *coins*))))

(defun how-old-is-ship (enemy-ship)
  (- (fiendish-rl.ffi:getticks) (enemy-ship-lifetime enemy-ship)))

(defun test-collisions ()
  ;; player vs debris
  (loop for d in *debris* do
       (when (aabb-overlap (+ 8 (player-ship-x *player-ship*)) (+ 8 (player-ship-y *player-ship*))
                           7 7
                           (+ 8 (debris-x d)) (+ 8 (debris-y d))
                           7 7)
         (setf *debris* (delete d *debris*))
         (setf *score* 0)
         (fiendish-rl.ffi:play-sound *destroy-sound*)))

  ;; player vs coins
  (loop for c in *coins* do
       (when (aabb-overlap (+ 8 (player-ship-x *player-ship*)) (+ 8 (player-ship-y *player-ship*))
                           7 7
                           (+ 8 (coin-x c)) (+ 8 (coin-y c))
                           7 7)
         (setf *coins* (delete c *coins*))
         (incf *score* 100)
         (incf *score* (length *enemy-ships*))
         (when (> *score* *max-score*)
           (setf *max-score* *score*))
         (fiendish-rl.ffi:play-sound *fire-sound*)
         (setf *enemy-ships* nil)))

  ;; player vs enemy ship
  (loop for d in *enemy-ships* do
       (when (aabb-overlap (+ 8 (player-ship-x *player-ship*)) (+ 8 (player-ship-y *player-ship*))
                           7 7
                           (+ 8 (enemy-ship-x d)) (+ 8 (enemy-ship-y d))
                           7 7)
         (setf *score* 0)
         (fiendish-rl.ffi:play-sound *destroy-sound*))))

(defun player-position-update ()
  (incf (player-ship-vel-x *player-ship*) (player-ship-accel-x *player-ship*))
  (incf (player-ship-vel-y *player-ship*) (player-ship-accel-y *player-ship*))

  (incf (player-ship-x *player-ship*) (player-ship-vel-x *player-ship*))
  (incf (player-ship-y *player-ship*) (player-ship-vel-y *player-ship*))

  (setf (player-ship-accel-x *player-ship*) 0
        (player-ship-accel-y *player-ship*) 0
        (player-ship-vel-x *player-ship*) (* 0.95 (player-ship-vel-x *player-ship*))
        (player-ship-vel-y *player-ship*) (* 0.95 (player-ship-vel-y *player-ship*)))

  (when (< (abs (player-ship-vel-x *player-ship*)) *epsilon*)
    (setf (player-ship-vel-x *player-ship*) 0))

  (when (< (abs (player-ship-vel-y *player-ship*)) *epsilon*)
    (setf (player-ship-vel-y *player-ship*) 0)))

(defun enemy-position-update (e)
  (incf (enemy-ship-dx e) (enemy-ship-accx e))
  (incf (enemy-ship-dy e) (enemy-ship-accy e))

  (incf (enemy-ship-x e) (enemy-ship-dx e))
  (incf (enemy-ship-y e) (enemy-ship-dy e))

  (setf (enemy-ship-accx e) 0
        (enemy-ship-accy e) 0
        (enemy-ship-dx e) (* 0.95 (enemy-ship-dx e))
        (enemy-ship-dy e) (* 0.95 (enemy-ship-dy e)))

  (when (< (abs (enemy-ship-dx e)) *epsilon*)
    (setf (enemy-ship-dx e) 0))

  (when (< (abs (enemy-ship-dy e)) *epsilon*)
    (setf (enemy-ship-dy e) 0)))


(defun update (tick)
  (loop for key-mod in (get-held-keys) do
       (apply #'handle-keypress key-mod))

  (player-position-update)

  (loop for e in *enemy-ships* do
       (enemy-position-update e))

  (loop for d in *debris* do
       (incf (debris-x d) (debris-dx d))
       (incf (debris-y d) (debris-dy d))

       (let ((ix (player-ship-x *player-ship*))
             (iy (player-ship-y *player-ship*)))
         (when (> (+ (abs (- ix (debris-x d)))
                     (abs (- iy (debris-y d))))
                  (* *screen-width* 3))
           (setf *debris* (delete d *debris*)))))
  
  (loop for c in *coins* do
       (decf (coin-to-flip c))
       (when (<= (coin-to-flip c) 0)
         (setf (coin-to-flip c) 30)
         (setf (coin-state c) (next-coin-state c))))

  (update-enemy-ships)
  (maybe-make-debris tick)
  (maybe-make-coin tick)
  (maybe-make-enemy-ship tick)
  (test-collisions))
       

(defun handle-keypress (key mod)
  (declare (ignore mod))
  (cond
    ((= key (char-code #\escape)) (setf *running* nil))
    ((= key (char-code #\d)) (move-player :right))
    ((= key (char-code #\a)) (move-player :left))
    ((= key (char-code #\w)) (move-player :up))
    ((= key (char-code #\s)) (move-player :down))
    ((= key 1073741906) (move-player :up))
    ((= key 1073741903) (move-player :right))
    ((= key 1073741905) (move-player :down))
    ((= key 1073741904) (move-player :left))))

(defun gameloop ()
  (setf *startup-time-ms* (fiendish-rl.ffi:getticks)
        *draw-count* 0
        *font* (fiendish-rl.ffi:open-font "DroidSansMono.ttf" 12)
        *next-tick-ms* 0
        *running* t
        *score* 0
        *max-score* 0
        *next-debris-check* 0
        *next-enemy-ship-check* 0)
  (clrhash *keyboard-state*)

  (fiendish-rl.ffi:set-texture-source "sprites.png")
  
  (loop while *running* do
       (let ((tick (fiendish-rl.ffi:getticks))
             (frame-skip 0))

         (loop while t do
              (destructuring-bind (result key mod) (fiendish-rl.ffi:pollevent)
                (if result
                    (keyboard-update result key mod)
                    (return))))                  
           
         (loop while (and (>= tick *next-tick-ms*) (< frame-skip *max-frame-skip*)) do
              (update (fiendish-rl.ffi:getticks))
              (incf *next-tick-ms* *ms-per-tick*)
              (incf frame-skip))
         
         (fiendish-rl.ffi:clear)
         (draw)
         (fiendish-rl.ffi:draw)
         (incf *draw-count*)))

  (let* ((end-time-ms (fiendish-rl.ffi:getticks))
         (elapsed-time (/ (- end-time-ms *startup-time-ms*) 1000.0))
         (average-fps (float (/ *draw-count* elapsed-time))))
    (format t "frames drawn = ~a~%" *draw-count*)
    (format t "gameloop elapsed time = ~a~%" elapsed-time)
    (format t "average fps = ~a~%" average-fps)))

(defun run ()
  (unwind-protect (progn (fiendish-rl.ffi:init "fiendish" 1280 720 *screen-width* *screen-height*)
                         (setf *destroy-sound* (fiendish-rl.ffi:load-sound "destroy.ogg")
                               *fire-sound* (fiendish-rl.ffi:load-sound "fire.ogg"))
                         (gameloop))
    (fiendish-rl.ffi:destroy)))
