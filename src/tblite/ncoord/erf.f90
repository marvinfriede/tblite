! This file is part of tblite.
! SPDX-Identifier: LGPL-3.0-or-later
!
! tblite is free software: you can redistribute it and/or modify it under
! the terms of the GNU Lesser General Public License as published by
! the Free Software Foundation, either version 3 of the License, or
! (at your option) any later version.
!
! tblite is distributed in the hope that it will be useful,
! but WITHOUT ANY WARRANTY; without even the implied warranty of
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
! GNU Lesser General Public License for more details.
!
! You should have received a copy of the GNU Lesser General Public License
! along with tblite.  If not, see <https://www.gnu.org/licenses/>.

!> @file tblite/ncoord/erf.f90
!> Provides a (standard) coordination number implementation for the CEH method

!> Coordination number implementation with single error function for the CEH and GP3-xTB methods.
module tblite_ncoord_erf
   use mctc_env, only : wp
   use mctc_io, only : structure_type
   use mctc_io_constants, only : pi
   use tblite_data_covrad, only : get_covalent_rad
   use tblite_ncoord_type, only : ncoord_type
   implicit none
   private

   public :: new_erf_ncoord

   !> Coordination number evaluator
   type, public, extends(ncoord_type) :: erf_ncoord_type
      real(wp), allocatable :: rcov(:)
   contains
      !> Evaluates the error counting function
      procedure :: ncoord_count
      !> Evaluates the derivative of the error counting function
      procedure :: ncoord_dcount
   end type erf_ncoord_type

   !> Steepness of counting function (CEH)
   real(wp), parameter :: default_kcn = 2.60_wp

   real(wp), parameter :: default_cutoff = 25.0_wp

contains


   subroutine new_erf_ncoord(self, mol, kcn, cutoff, rcov)
      !> Coordination number container
      type(erf_ncoord_type), intent(out) :: self
      !> Molecular structure data
      type(structure_type), intent(in) :: mol
      !> Steepness of counting function
      real(wp), optional :: kcn
      !> Real space cutoff
      real(wp), intent(in), optional :: cutoff
      !> Covalent radii
      real(wp), intent(in), optional :: rcov(:)

      if(present(kcn)) then
         self%kcn = kcn
      else
         self%kcn = default_kcn
      end if

      if (present(cutoff)) then
         self%cutoff = cutoff
      else
         self%cutoff = default_cutoff
      end if

      allocate(self%rcov(mol%nid))
      if (present(rcov)) then
         self%rcov(:) = rcov
      else
         self%rcov(:) = get_covalent_rad(mol%num)
      end if

      self%directed_factor = 1.0_wp

   end subroutine new_erf_ncoord

   !> Error counting function for coordination number contributions.
   elemental function ncoord_count(self, mol, izp, jzp, r) result(count)
      !> Coordination number container
      class(erf_ncoord_type), intent(in) :: self
      !> Molecular structure data (not used in std)
      type(structure_type), intent(in) :: mol
      !> Atom i index
      integer, intent(in)  :: izp
      !> Atom j index
      integer, intent(in)  :: jzp
      !> Current distance.
      real(wp), intent(in) :: r

      real(wp) :: rc, count
      
      rc = (self%rcov(izp) + self%rcov(jzp))
      ! error function based counting function
      count = 0.5_wp * (1.0_wp + erf(-self%kcn*(r-rc)/rc))
      
   end function ncoord_count

   !> Derivative of the error counting function w.r.t. the distance.
   elemental function ncoord_dcount(self, mol, izp, jzp, r) result(count)
      !> Coordination number container
      class(erf_ncoord_type), intent(in) :: self
      !> Molecular structure data (not used in std)
      type(structure_type), intent(in) :: mol
      !> Atom i index
      integer, intent(in)  :: izp
      !> Atom j index
      integer, intent(in)  :: jzp
      !> Current distance.
      real(wp), intent(in) :: r

      real(wp) :: rc, exponent, expterm, count

      rc = self%rcov(izp) + self%rcov(jzp)
      ! error function based counting function with EN derivative
      exponent = self%kcn*(r-rc)/rc
      expterm = exp(-exponent**2)
      count = -(self%kcn*expterm)/(rc*sqrt(pi))

   end function ncoord_dcount

end module tblite_ncoord_erf
